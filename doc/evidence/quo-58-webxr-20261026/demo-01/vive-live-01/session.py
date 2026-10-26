"""Live production HTTPS acceptance. VR entry is an explicit operator command.

JSON commands arrive over stdin. The campaign remains open until stop/EOF;
there is no frame-count stop. Browser credentials remain in the private profile.
"""
import base64, json, os, pathlib, re, selectors, signal, subprocess, sys, threading, time, urllib.request, urllib.error

root = pathlib.Path('/home/yan/src/quod')
evidence = pathlib.Path(__file__).resolve().parent
state = root/'_build/quo-58-webxr-20261026/demo-01/vive-live-01'
profile = root/'_build/quo-58-webxr-20261026/demo-01/browser-profile'
base = root/'client/_build/webxr-linux'
url = 'https://192.168.1.10:30519/'
children, logs, changed_display = [], [], False
session, endpoint, before, headset = None, None, None, None
trust_installed = False

def interrupted(signum, frame):
    raise SystemExit('Test runner received signal '+str(signum))

signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)
result = {'origin':url,'simulation':False,'automatic_vr_entry':False}

def save(name, value):
    with (evidence/name).open('x') as out: json.dump(value,out,indent=2)

def desktop_geometry(rows, headset_name):
    fields=['name','width','height','x','y','refreshRate','scale','disabled']
    return sorted([{k:m[k] for k in fields} for m in rows if m['name']!=headset_name],key=lambda m:m['name'])

def request(method, path, body=None):
    req = urllib.request.Request(endpoint+path, method=method,
        data=None if body is None else json.dumps(body).encode(), headers={'Content-Type':'application/json'})
    try:
        with urllib.request.urlopen(req,timeout=45) as response: return json.load(response)['value']
    except urllib.error.HTTPError as error: raise RuntimeError(error.read().decode()) from error

def command(path, body=None): return request('POST','/session/'+session+path,body or {})
def evaluate(script, args=None): return command('/execute/sync',{'script':script,'args':args or []})

def start(executable,args,name,pattern):
    log=(evidence/(name+'.log')).open('x'); logs.append(log)
    process=subprocess.Popen([str(executable),*args],env=env,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    children.append((name,process))
    data=b''; deadline=time.monotonic()+30
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout,selectors.EVENT_READ)
        while not (match := re.search(pattern,data)):
            remaining=deadline-time.monotonic()
            if remaining <= 0 or not selector.select(remaining): raise RuntimeError(name+' startup deadline exceeded')
            chunk=os.read(process.stdout.fileno(),65536)
            if not chunk: raise RuntimeError(name+' exited during startup')
            data+=chunk; log.write(chunk.decode(errors='replace')); log.flush()
    def drain():
        for line in process.stdout: log.write(line.decode(errors='replace')); log.flush()
    threading.Thread(target=drain,daemon=True).start()
    return match

def status(label):
    value=evaluate('''return {url:location.href, title:document.title, secure:isSecureContext,
      text:document.body.innerText.slice(0,20000), measurement:window.quodAcceptance,
      controls:Array.from(document.querySelectorAll('button,input,select,textarea')).map(e=>({
        tag:e.tagName,type:e.type,text:e.innerText?.slice(0,120),id:e.id,
        label:e.getAttribute('aria-label') ?? (e.labels?.[0]?.innerText ?? ''),
        value:e.type==='password' ? '[redacted]' : e.value,disabled:e.disabled,
        visible:!!(e.offsetWidth||e.offsetHeight||e.getClientRects().length),
        options:e.options ? Array.from(e.options,o=>({label:o.label,value:o.value})) : undefined}))}''')
    value['processes']={name:process.poll() for name,process in children}
    save(label+'.json',value)
    save(label+'-console.json',command('/log',{'type':'browser'}))
    measurement=value.get('measurement') or {}
    compact={**value,'text':value.get('text','')[:6500],
        'measurement':{**measurement,'resources_count':len(measurement.get('resources',[])),
          'resources':measurement.get('resources',[])[-8:],
          'sessions':[{**r,'samples':r.get('samples',[])[-2:]} for r in measurement.get('sessions',[])]}}
    print(json.dumps(compact),flush=True)

def click(text):
    element=evaluate('''const found=Array.from(document.querySelectorAll('button')).filter(e=>
      e.innerText.trim()===arguments[0] && !e.disabled && e.getClientRects().length);
      if(found.length!==1) throw new Error('Expected exactly one available button: '+arguments[0]); return found[0]''',[text])
    command('/element/'+element['element-6066-11e4-a52e-4f735466cecf']+'/click')

def open_browser(label):
    global session
    created=request('POST','/session',{'capabilities':{'alwaysMatch':{
        'browserName':'chrome','acceptInsecureCerts':False,'goog:loggingPrefs':{'browser':'ALL'},
        'goog:chromeOptions':{'binary':str(base/'chromium/src/out/QuodWebXR/chrome'),'args':[
            '--enable-features=OpenXR','--ozone-platform=wayland','--no-first-run',
            '--no-default-browser-check','--window-size=1400,1000','--user-data-dir='+str(profile)]}}}})
    session=created['sessionId'];save(label,created['capabilities'])
    assert created['capabilities']['acceptInsecureCerts'] is False
    command('/timeouts',{'script':30000,'pageLoad':30000})
    command('/goog/cdp/execute',{'cmd':'Page.addScriptToEvaluateOnNewDocument',
        'params':{'source':(evidence/'observe.js').read_text()}})
    command('/url',{'url':url})


try:
    state.mkdir(mode=0o700,exist_ok=False)
    profile.mkdir(mode=0o700, exist_ok=False)
    trust=subprocess.run([sys.executable,str(evidence/'trust.py'),'install'])
    trust_installed=trust.returncode==0
    assert trust_installed, 'Exact certificate trust setup failed'
    state.chmod(0o700)
    for name in ['runtime','config','cache','data']:(state/name).mkdir(mode=0o700,exist_ok=False)
    display=pathlib.Path(os.environ['WAYLAND_DISPLAY'])
    if not display.is_absolute():display=pathlib.Path(os.environ['XDG_RUNTIME_DIR'])/display
    (state/'runtime/wayland-display').symlink_to(display)
    env={k:v for k,v in os.environ.items() if not k.startswith(('SIMULATED_','XRT_COMPOSITOR_FORCE_'))}
    for key in ['LD_PRELOAD','LD_LIBRARY_PATH']:env.pop(key,None)
    env.update(XDG_RUNTIME_DIR=str(state/'runtime'),XDG_CONFIG_HOME=str(state/'config'),
        XDG_CACHE_HOME=str(state/'cache'),XDG_DATA_HOME=str(state/'data'),WAYLAND_DISPLAY='wayland-display',
        XR_RUNTIME_JSON=str(base/'monado-build/openxr_monado-dev.json'),XRT_NO_STDIN='1',
        SIMULATED_ENABLE='0',STEAMVR_LH_ENABLE='1',XRT_COMPOSITOR_FORCE_WAYLAND_DIRECT='1',
        STEAMVR_PATH='/home/yan/.local/share/Steam/steamapps/common/SteamVR')
    match=start(base/'chrome-testing/chromedriver-linux64/chromedriver',['--port=0'],'chromedriver',rb'started successfully on port (\d+)')
    endpoint='http://127.0.0.1:'+match[1].decode()
    open_browser('capabilities.json')
    save('owner.json',{'pid':os.getpid(),'children':{n:p.pid for n,p in children},'webdriver_session':session})
    print('BROWSER_OPEN; VR has not been requested.',flush=True)
    for line in sys.stdin:
        item=json.loads(line);action=item['action']
        if action=='stop':break
        try:
            if action=='status':status(item['label'])
            elif action=='click':click(item['text'])
            elif action=='wait-button':
                value=command('/execute/async',{'script':'''
                  const text=arguments[0], done=arguments[arguments.length-1], started=performance.now();
                  let finished=false;
                  const finish=ready=>{if(finished)return;finished=true;observer.disconnect();
                    clearTimeout(deadline);done({ready,elapsedMs:performance.now()-started});};
                  const check=()=>{if(Array.from(document.querySelectorAll('button')).some(e=>
                    e.innerText.trim()===text && !e.disabled && e.getClientRects().length))finish(true);};
                  const observer=new MutationObserver(check);
                  observer.observe(document.documentElement,{subtree:true,childList:true,
                    characterData:true,attributes:true});
                  const deadline=setTimeout(()=>finish(false),25000);check();
                ''','args':[item['text']]})
                save(item['label']+'.json',value);print(json.dumps(value),flush=True)
            elif action=='eval':print(json.dumps({'value':evaluate(item['script'],item.get('args'))}),flush=True)
            elif action=='screenshot':
                data=request('GET','/session/'+session+'/screenshot')
                with (evidence/(item['label']+'.png')).open('xb') as out:out.write(base64.b64decode(data))
            elif action=='enable-display':
                assert not changed_display
                before=json.loads(subprocess.check_output(['hyprctl','monitors','all','-j']))
                save('monitors-before.json',before)
                matches=[m for m in before if m['description']=='HTC Corportation HTC-VIVE']
                assert len(matches)==1;headset=matches[0]
                changed_display=True
                subprocess.run(['hyprctl','eval','hl.monitor({output="desc:HTC Corportation HTC-VIVE", disabled=false})'],check=True)
                enabled=json.loads(subprocess.check_output(['hyprctl','monitors','all','-j']))
                save('monitors-enabled.json',enabled)
                assert desktop_geometry(before,headset['name'])==desktop_geometry(enabled,headset['name'])
                print('DISPLAY_ENABLED; waiting for explicit cable-reconnection observation before runtime startup.',flush=True)
            elif action=='runtime':
                assert changed_display, 'Enable and verify the headset display first'
                assert item.get('cable_reconnected') is True, 'Await the actual reconnection observation'
                assert not any(name=='runtime' for name,process in children), 'One runtime attempt per campaign'
                reconnected=json.loads(subprocess.check_output(['hyprctl','monitors','all','-j']))
                save('monitors-after-reconnect.json',reconnected)
                assert desktop_geometry(before,headset['name'])==desktop_geometry(reconnected,headset['name'])
                start(base/'monado-build/src/xrt/targets/service/monado-service',[],'runtime',b'The Monado service has started.')
                # This qualified Chromium caches API unavailability at device
                # service startup. Reopen only our browser after Monado starts,
                # keeping its original profile and normal recovery journal.
                status('before-runtime-browser-reopen')
                request('DELETE','/session/'+session);session=None
                open_browser('runtime-capabilities.json')
                save('runtime-owners.json',{'children':{n:p.pid for n,p in children},'webdriver_session':session})
                print('RUNTIME_STARTED; browser reopened; physical stereo and tracking remain unverified.',flush=True)
            elif action=='enter-vr':
                assert item.get('yan_ready') is True
                click('Enter VR')
            elif action=='exit-vr':click('Exit VR')
            elif action=='platform-exit':evaluate('if(window.quodAcceptanceSession) window.quodAcceptanceSession.end(); return true')
            
            elif action=='reload':command('/refresh')
            else:raise RuntimeError('Unknown command')
            print(json.dumps({'action':action,'completed':True}),flush=True)
        except Exception as error:
            print(json.dumps({'action':action,'error':str(error),'resubmitted':False}),flush=True)
            if action=='runtime':raise
except BaseException as error:
    result['error']=str(error)
finally:
    if session:
        try:status('final-observation')
        except Exception as error:result['final_observation_error']=str(error)
        try:request('DELETE','/session/'+session)
        except Exception as error:result['browser_stop_error']=str(error)
    for name,process in reversed(children):
        if process.poll() is None:process.terminate()
        try:result[name+'_exit']=process.wait(timeout=15)
        except subprocess.TimeoutExpired:process.kill();result[name+'_exit']=process.wait()
    if changed_display:
        restored=subprocess.run(['hyprctl','eval','hl.monitor({output="desc:HTC Corportation HTC-VIVE", disabled='+str(headset['disabled']).lower()+'})'],capture_output=True,text=True)
        result['restore_exit']=restored.returncode
        after=json.loads(subprocess.check_output(['hyprctl','monitors','all','-j']));save('monitors-after.json',after)
        result['desktop_geometry_preserved']=desktop_geometry(before,headset['name'])==desktop_geometry(after,headset['name'])
        result['headset_state_restored']=any(m['name']==headset['name'] and m['disabled']==headset['disabled'] for m in after)
    if trust_installed:
        removed=subprocess.run([sys.executable,str(evidence/'trust.py'),'remove'])
        result['trust_remove_exit']=removed.returncode
    result['unexpected_child_exits']={name:result.get(name+'_exit') for name,process in children
        if result.get(name+'_exit') not in (0,-15)}
    save('result.json',result);print(json.dumps(result),flush=True)
    sys.exit(1 if 'error' in result or result['unexpected_child_exits'] or result.get('trust_remove_exit',0) or result.get('restore_exit',0) or
             result.get('desktop_geometry_preserved') is False or
             result.get('headset_state_restored') is False else 0)
