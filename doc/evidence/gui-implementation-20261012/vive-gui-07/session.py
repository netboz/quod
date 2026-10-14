"""Interactive hardware campaign, using the previously qualified native owners."""
import json, os, pathlib, re, selectors, subprocess, sys, tempfile, threading, time, urllib.request, urllib.error

root = pathlib.Path('/home/yan/src/quod')
evidence = pathlib.Path(__file__).resolve().parent
base = root / 'client/_build/webxr-linux'
children = []
logs = []
session = None
endpoint = None
profile = None
before = json.loads(subprocess.check_output(['hyprctl', 'monitors', 'all', '-j']))
(evidence / 'monitors-before.json').write_text(json.dumps(before, indent=2))
headset = next(m for m in before if m['description'] == 'HTC Corportation HTC-VIVE')
result = {'device': 'physical Vive', 'simulation': False, 'headset_only': False}

def request(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(endpoint + path, data=data, method=method,
                                 headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=45) as response:
            return json.load(response)['value']
    except urllib.error.HTTPError as error:
        raise RuntimeError(error.read().decode()) from error

def command(path, body=None):
    return request('POST', '/session/' + session + path, body or {})

def evaluate(script):
    return command('/execute/sync', {'script': script, 'args': []})

def start(executable, args, env, name, pattern):
    log = (evidence / (name + '.log')).open('x')
    logs.append(log)
    process = subprocess.Popen([str(executable), *args], env=env, cwd=root/'ui',
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    children.append((name, process))
    data = b''
    deadline = time.monotonic() + 30
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        while not (match := re.search(pattern, data)):
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not selector.select(remaining):
                raise RuntimeError(name + ' startup deadline exceeded')
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk: raise RuntimeError(name + ' exited during startup')
            data += chunk
            log.write(chunk.decode(errors='replace')); log.flush()
    def drain():
        for line in process.stdout:
            log.write(line.decode(errors='replace')); log.flush()
    threading.Thread(target=drain, daemon=True).start()
    return match

try:
    start(root/'ui/node_modules/.bin/vite', ['--host','127.0.0.1','--port','5178','--strictPort'],
          os.environ.copy(), 'fixture-server', rb'Local:')
    subprocess.run(['hyprctl', 'eval', 'hl.monitor({output="desc:HTC Corportation HTC-VIVE", disabled=false})'], check=True)
    profile = tempfile.TemporaryDirectory(prefix='quod-gui-vive-')
    directory = profile.name
    if directory:
        state = pathlib.Path(directory)
        for name in ['runtime', 'config', 'cache', 'data']:
            (state / name).mkdir(mode=0o700)
        display = pathlib.Path(os.environ['WAYLAND_DISPLAY'])
        if not display.is_absolute(): display = pathlib.Path(os.environ['XDG_RUNTIME_DIR']) / display
        (state / 'runtime/wayland-display').symlink_to(display)
        env = {k:v for k,v in os.environ.items() if not k.startswith(('SIMULATED_', 'XRT_COMPOSITOR_FORCE_'))}
        env.update(XDG_RUNTIME_DIR=str(state/'runtime'), XDG_CONFIG_HOME=str(state/'config'),
                   XDG_CACHE_HOME=str(state/'cache'), XDG_DATA_HOME=str(state/'data'),
                   WAYLAND_DISPLAY='wayland-display', XR_RUNTIME_JSON=str(base/'monado-build/openxr_monado-dev.json'),
                   XRT_NO_STDIN='1', SIMULATED_ENABLE='0', STEAMVR_LH_ENABLE='1',
                   STEAMVR_PATH='/home/yan/.local/share/Steam/steamapps/common/SteamVR',
                   XRT_COMPOSITOR_FORCE_WAYLAND_DIRECT='1')
        start(base/'monado-build/src/xrt/targets/service/monado-service', [], env, 'runtime', b'The Monado service has started.')
        match = start(base/'chrome-testing/chromedriver-linux64/chromedriver', ['--port=0'], env,
                      'chromedriver', rb'started successfully on port (\d+)')
        endpoint = 'http://127.0.0.1:' + match[1].decode()
        created = request('POST', '/session', {'capabilities': {'alwaysMatch': {
            'browserName': 'chrome', 'goog:loggingPrefs': {'browser':'ALL'},
            'goog:chromeOptions': {'binary':str(base/'chromium/src/out/QuodWebXR/chrome'), 'args':[
                '--enable-features=OpenXR', '--ozone-platform=wayland', '--no-first-run',
                '--no-default-browser-check', '--window-size=1200,900',
                '--user-data-dir='+str(state/'data/profile')]}}}})
        session = created['sessionId']
        (evidence/'capabilities.json').write_text(json.dumps(created['capabilities'],indent=2))
        command('/timeouts', {'script':30000,'pageLoad':30000})
        command('/goog/cdp/execute', {'cmd':'Browser.grantPermissions',
                                    'params':{'origin':'http://localhost:5178','permissions':['vr']}})
        command('/url', {'url':'http://localhost:5178/test/gui-hardware.fixture.html'})
        ready = command('/execute/async', {'script': "const done=arguments[arguments.length-1]; import('/test/gui-hardware.fixture.js').then(async()=>done({secure:isSecureContext,xrSupported:await navigator.xr.isSessionSupported('immersive-vr'),report:window.guiHardwareReport()})).catch(e=>done({error:String(e)}))", 'args': []})
        (evidence/'ready.json').write_text(json.dumps(ready,indent=2))
        (evidence/'connection.json').write_text(json.dumps({'endpoint':endpoint,'session':session},indent=2))
        print(json.dumps({'ready':ready}),flush=True)
        if ready.get('error') or not ready.get('secure') or not ready.get('xrSupported'):
            raise RuntimeError('WebXR preparation failed: '+str(ready))
        print('READY; click Enter VR when ready. Commands: status, opaque, translucent, bright, dark, center, stop',flush=True)
        for line in sys.stdin:
            action = line.strip()
            if action == 'stop': break
            if action in ['opaque','translucent']:
                evaluate('window.guiHardwareOpacity('+('1' if action=='opaque' else '0.78')+'); return true')
            if action in ['bright','dark']: evaluate('window.guiHardwareBackground('+('0.9' if action=='bright' else '0.08')+'); return true')
            if action == 'center': evaluate('document.querySelector("#show").click(); return true')
            current = evaluate('return window.guiHardwareReport()')
            (evidence/'latest-report.json').write_text(json.dumps(current,indent=2))
            print(json.dumps(current),flush=True)
        result['report'] = evaluate('return window.guiHardwareReport()')
        (evidence/'console.json').write_text(json.dumps(command('/log',{'type':'browser'}),indent=2))
        request('DELETE','/session/'+session);session=None
except BaseException as error:
    result['error'] = str(error)
finally:
    if session:
        try: request('DELETE','/session/'+session)
        except Exception: pass
    for name, process in reversed(children):
        if process.poll() is None: process.terminate()
        try: result[name+'_exit'] = process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill();result[name+'_exit'] = process.wait()
    if profile: profile.cleanup()
    restored = subprocess.run(['hyprctl','eval','hl.monitor({output="desc:HTC Corportation HTC-VIVE", disabled='+str(headset['disabled']).lower()+'})'],capture_output=True,text=True)
    result['restore_exit'] = restored.returncode
    after = json.loads(subprocess.check_output(['hyprctl','monitors','all','-j']))
    (evidence/'monitors-after.json').write_text(json.dumps(after,indent=2))
    fields=['name','width','height','x','y','refreshRate','scale','disabled']
    summarize=lambda rows: sorted([{k:m[k] for k in fields} for m in rows if m['name']!=headset['name']],key=lambda m:m['name'])
    result['desktop_geometry_preserved'] = summarize(before)==summarize(after)
    (evidence/'result.json').write_text(json.dumps(result,indent=2))
    print(json.dumps(result),flush=True)

sys.exit(1 if result.get('error') or result.get('restore_exit') else 0)
