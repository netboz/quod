"""Separate human-assisted HDMI hotplug observation; never an automated retry."""
import json,os,subprocess,sys,threading
from environment import TASK
from vive_display import ViveDisplay
label=sys.argv[1];private=TASK/'private'/label;private.mkdir(mode=0o700,exist_ok=False)
display=ViveDisplay(private);child=None;ready=threading.Event();offered=threading.Event();errors=[];record={'manual_display_preflight':True,'application_or_hardware_acceptance':False}
stream=(private/'protocol.log').open('xb');reader=None
try:
    child=subprocess.Popen([str(TASK/'builds/display-inventory02/display-inventory'),'--await-connector'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    def receive():
        try:
            for line in child.stdout:
                stream.write(line);stream.flush()
                if line.startswith(b'WAIT_CONNECTOR'):ready.set()
                if line.startswith(b'LEASE_NOTIFICATION'):offered.set();print('VIVE_LEASE_OFFER_OBSERVED',flush=True)
        except Exception as error:errors.append(type(error).__name__)
        finally:ready.set()
    reader=threading.Thread(target=receive);reader.start()
    if not ready.wait(timeout=10) or child.poll() is not None:raise RuntimeError('Owned read-only observer not ready')
    display.enable();print('VIVE_RECONNECT_OBSERVER_READY',flush=True)
    control=sys.stdin.readline().strip();record['participant_response']=control
    if control=='finish':record['lease_offer']=offered.wait(timeout=10)
    else:record['lease_offer']=offered.is_set()
finally:
    if child is not None and child.poll() is None:child.kill()
    if child is not None:record['observer_exit']=child.wait(timeout=5);record['observer_stderr']=child.stderr.read().decode()
    if reader:reader.join(timeout=5);record['reader_eof']=not reader.is_alive()
    stream.close();record['reader_errors']=errors;display.restore()
    record['display_preserved']=display.record['desktop_unchanged'] and display.record['config_unchanged']
    (private/'result.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record));print(json.dumps(display.record))
if record.get('participant_response')!='finish' or not record.get('lease_offer') or errors:raise SystemExit(1)
