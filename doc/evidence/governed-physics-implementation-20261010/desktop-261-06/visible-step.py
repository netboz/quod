from pathlib import Path
import json, subprocess, sys
import browser as b

p=Path(__file__).resolve().parent
label,key,duration=sys.argv[1:]
owned=json.loads((p/'compositor-placement.json').read_text())['browser']
clients=json.loads(subprocess.check_output(['hyprctl','-j','clients'],text=True))
current=next(x for x in clients if x['pid']==owned['pid'] and x['address']==owned['address'])
action='hl.dsp.focus({window = '+json.dumps('address:'+current['address'])+'})'
focused=subprocess.run(['hyprctl','dispatch',action],capture_output=True,text=True)
assert focused.returncode==0,(focused.stdout,focused.stderr)
cadence=b.command('/execute/async',{'script':'''const done=arguments[0], ts=[];
let ended=false;const finish=reason=>{if(ended)return;ended=true;clearTimeout(timer);
done({reason,timestamps:ts,hidden:document.hidden,focused:document.hasFocus()})};
const timer=setTimeout(()=>finish('deadline'),3000);
const frame=t=>{if(ended)return;ts.push(t);if(ts.length===9)finish('complete');
else requestAnimationFrame(frame)};requestAnimationFrame(frame);''','args':[]})
active=json.loads(subprocess.check_output(['hyprctl','-j','activewindow'],text=True))
result={'cadence':cadence,'active_pid':active.get('pid'),'expected_pid':owned['pid']}
with (p/(label+'-visibility.json')).open('x') as f:json.dump(result,f,indent=2)
print(json.dumps(result),flush=True)
assert cadence['reason']=='complete' and active.get('pid')==owned['pid']
raise SystemExit(subprocess.run([sys.executable,str(p/'desktop-step.py'),label,key,duration]).returncode)
