import json,os,selectors,subprocess,time
from environment import TASK
from vive_display import ViveDisplay
private=TASK/'private/display-rule01';private.mkdir(mode=0o700,exist_ok=False)
display=ViveDisplay(private);child=None;data=b'';record={'passed':False};deadline=time.monotonic()+20
try:
    child=subprocess.Popen([str(TASK/'builds/display-inventory02/display-inventory'),'--await-connector'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    selector=selectors.DefaultSelector();selector.register(child.stdout,selectors.EVENT_READ)
    while True:
        left=deadline-time.monotonic()
        if left<=0 or not selector.select(left):raise TimeoutError('No connector notification within bounded observation')
        block=os.read(child.stdout.fileno(),65536)
        if not block:break
        data+=block
        if b'WAIT_CONNECTOR\n' in data and not display.changed:display.enable()
    record['child_exit']=child.wait(timeout=5);record['stderr']=child.stderr.read().decode()
    record['connector_notification']=b'LEASE_NOTIFICATION connectors=1' in data
    record['passed']=record['child_exit']==0 and record['connector_notification']
finally:
    if child is not None and child.poll() is None:child.kill();record['child_exit']=child.wait()
    (private/'protocol.log').write_bytes(data)
    display.restore();record['display_preserved']=display.record['desktop_unchanged'] and display.record['config_unchanged']
    (private/'result.json').write_text(json.dumps(record,indent=2)+'\n')
    print(data.decode());print(json.dumps(record));print(json.dumps(display.record))
if not record['passed']:raise SystemExit(1)
