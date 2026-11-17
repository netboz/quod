"""One bounded disposable transport probe; never launches a product or runtime."""
import json,os,select,sys
ready=select.select([0],[],[],5)[0]
data=os.read(0,16) if ready else None
print(json.dumps({'tty':os.isatty(0),'stdin_ready':bool(ready),'stdin_eof':data==b'',
    'expected_finish_received':data==b'finish\n','scope':'Owned disposable control stream only; no application, device or domain action.'}),flush=True)
raise SystemExit(0 if data in [b'',b'finish\n'] else 1)
