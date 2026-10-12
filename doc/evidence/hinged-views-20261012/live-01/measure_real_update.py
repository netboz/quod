from pathlib import Path
import subprocess,json,selectors,os,time,base64
import owner,console as c,browser as b,wait_frame as w,capture_scene03 as cap
p=Path(__file__).resolve().parent;ns='human:5pU3X8evhfH09g1ctl0LRRP80zmhd6M7g8OQ7DyOeaE/lobby'
q='binary_to_list(base64:encode(iolist_to_binary(json:encode(quod36_work_probe:updated(<<"'+ns+'">>,8))))).'
cmd=['nomad','alloc','exec','-i=false','-t=false','-address=http://192.168.1.10:4646','-task','quod',owner.allocation,'/opt/quod/bin/quod','eval',q]
with (p/'personal-obstacle-update-measure.intent.json').open('x') as f:json.dump({'expression':q,'read_only_trace':True,'change':'ordinary signed console shared move body7 to revision8'},f,indent=2)
proc=subprocess.Popen(cmd,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
try:
 with selectors.DefaultSelector() as sel:
  sel.register(proc.stdout,selectors.EVENT_READ);assert sel.select(15),'trace preparation deadline'
 first=proc.stdout.readline();assert first.strip()=='TRACE_READY',first
 c.open_console();goal='<<"'+ns+'">>::(Z is -4000,physics_move_body(personal_lobby,7,7,7,vector(4000,1200,Z))).'
 r=c.prove('personal-obstacle-clear',goal);assert 'true — committed' in r['text'],r['text'][-1000:]
 out,err=proc.communicate(timeout=35)
 with (p/'personal-obstacle-update-measure.stdout').open('x') as f:f.write(first+out)
 with (p/'personal-obstacle-update-measure.stderr').open('x') as f:f.write(err)
 with (p/'personal-obstacle-update-measure.exit.json').open('x') as f:json.dump({'exit':proc.returncode},f)
 assert proc.returncode==0,err
 wire=json.loads(out)
 if isinstance(wire,list):wire=bytes(wire).decode()
 a=json.loads(base64.b64decode(wire));(p/'personal-obstacle-update-measure.json').write_text(json.dumps(a,indent=2))
 assert a['result']['real_structure']==8,a
 c.button('Return to lobby');w.wait(8,7,8);cap.capture('personal-obstacle-cleared-visible')
 print(json.dumps({'work':a['work'],'actual_shared_update':True}))
except BaseException as e:
 if proc.poll() is None:proc.terminate()
 (p/'personal-obstacle-update-measure.STOP.json').write_text(json.dumps({'type':type(e).__name__,'reason':str(e),'rule':'Resolve original console operation; never rerun'})+'\n');raise
