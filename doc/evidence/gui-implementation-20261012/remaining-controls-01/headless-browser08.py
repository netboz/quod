"""Software-only browser gate: no window, native XR runtime or display changes."""
import hashlib, json, os, pathlib, re, selectors, shutil, subprocess, tempfile, threading, time, urllib.request, urllib.error

root = pathlib.Path('/home/yan/src/quod')
packet = pathlib.Path(__file__).resolve().parent
base = root / 'client/_build/webxr-linux'
children, logs = [], []
session = None
endpoint = None
result = {}
profile = None

def start(executable, args, name, pattern):
    log = (packet / (name + '.log')).open('x')
    logs.append(log)
    process = subprocess.Popen([str(executable), *args], cwd=root/'ui',
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

def request(path, body=None, method='POST'):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(endpoint + path, data=data, method=method,
                                 headers={'Content-Type':'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=65) as response:
            return json.load(response)['value']
    except urllib.error.HTTPError as error:
        raise RuntimeError(error.read().decode(errors='replace')) from error

try:
    start(root/'ui/node_modules/.bin/vite', ['--host','127.0.0.1','--port','5178','--strictPort'],
          'fixture-server08', rb'Local:')
    match = start(base/'chrome-testing/chromedriver-linux64/chromedriver', ['--port=0'],
                  'chromedriver08', rb'started successfully on port (\d+)')
    endpoint = 'http://127.0.0.1:' + match[1].decode()
    profile = tempfile.mkdtemp(prefix='quod-gui-headless-')
    created = request('/session', {'capabilities': {'alwaysMatch': {
        'browserName':'chrome', 'goog:loggingPrefs':{'browser':'ALL'},
        'goog:chromeOptions':{'binary':str(base/'chromium/src/out/QuodWebXR/chrome'),
            'args':['--headless=new', '--no-first-run', '--no-default-browser-check',
                    '--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader',
                    '--window-size=1440,1100', '--user-data-dir='+profile]}}}})
    session = created['sessionId']
    prefix = '/session/' + session
    request(prefix+'/timeouts', {'script':60000,'pageLoad':30000})
    request(prefix+'/url', {'url':'http://localhost:5178/test/workspace-panel.fixture.html'})
    value = request(prefix+'/execute/async', {'script':"""
      const done = arguments[arguments.length - 1];
      window.exerciseWorkspacePanel().then(({screenshot, ...value}) => done({value}),
        error => done({error:String(error.stack ?? error)}));
    """, 'args':[]})
    (packet/'browser-result08.json').write_text(json.dumps(value,indent=2)+'\n')
    console = request(prefix+'/log', {'type':'browser'})
    (packet/'browser-console08.json').write_text(json.dumps(console,indent=2)+'\n')
    assert 'error' not in value, value
    checks = value['value']
    subprocess.run(['node', '--input-type=module', '-e', "import fs from 'node:fs'; import {checkWorkspacePanelResult} from './client/test/workspace-panel.browser.mjs'; checkWorkspacePanelResult(JSON.parse(fs.readFileSync(process.argv[1])).value)", str(packet/'browser-result08.json')], cwd=root, check=True)
    assert all(v for v in checks.values() if isinstance(v,bool)), checks
    assert checks['nodeMaterialRoundtrip'] and checks['xrFeatures']
    assert checks['typed'] == 'a(X).' and checks['activations'] == 1
    assert checks['browserErrors'] == [], checks['browserErrors']
    assert not [e for e in console if e['level']=='SEVERE' and not (e['source']=='network' and '/favicon.ico - Failed to load resource: the server responded with a status of 404' in e['message'])], console
    request(prefix+'/url', {'url':'http://localhost:5178/test/gui-form.fixture.html'})
    desktop = request(prefix+'/execute/async', {'script':"""
      const done = arguments[arguments.length - 1];
      window.exerciseGuiForm().then(value => done({value}),
        error => done({error:String(error.stack ?? error)}));
    """, 'args':[]})
    (packet/'desktop-result08.json').write_text(json.dumps(desktop,indent=2)+'\n')
    desktop_console = request(prefix+'/log', {'type':'browser'})
    (packet/'desktop-console08.json').write_text(json.dumps(desktop_console,indent=2)+'\n')
    assert 'error' not in desktop, desktop
    assert all(desktop['value']['checks'].values()), desktop
    assert desktop['value']['errors'] == [], desktop
    assert not [e for e in desktop_console if e['level']=='SEVERE' and not (e['source']=='network' and '/favicon.ico - Failed to load resource: the server responded with a status of 404' in e['message'])], desktop_console
    result['desktop_checks'] = len(desktop['value']['checks'])
    request(prefix+'/url', {'url':'http://localhost:5178/test/gui-hardware.fixture.html'})
    hardware = request(prefix+'/execute/async', {'script': "const done=arguments[arguments.length-1]; import('/test/gui-hardware.fixture.js').then(()=>done(window.guiHardwareReport()), error=>done({error:String(error)}));", 'args':[]})
    (packet/'hardware-result08.json').write_text(json.dumps(hardware,indent=2)+'\n')
    assert 'error' not in hardware and hardware['errors'] == [] and hardware['entries'] == 0, hardware
    assert {'tabs','table','dialog','menu','image','text_area','number_input','checkbox','toggle','radio_group','selectable_list'}.issubset({c['kind'] for c in hardware['controls']})
    hardware_console = request(prefix+'/log', {'type':'browser'})
    (packet/'hardware-console08.json').write_text(json.dumps(hardware_console,indent=2)+'\n')
    assert not [e for e in hardware_console if e['level']=='SEVERE' and not (e['source']=='network' and '/favicon.ico - Failed to load resource: the server responded with a status of 404' in e['message'])], hardware_console
    result['hardware_fixture_loaded_without_xr'] = True
    manifest = json.loads((packet/'manifest08.json').read_text())
    assert all(hashlib.sha256((root/f).read_bytes()).hexdigest()==h for f,h in manifest.items())
    result.update(passed=True, unchanged=True, boolean_checks=sum(isinstance(v,bool) for v in checks.values()))
    request(prefix, method='DELETE'); session = None
except Exception as error:
    result.update(passed=False, error=str(error))
    if session:
        try:
            diagnostic = request('/session/'+session+'/execute/sync', {'script': "return {stage:window.guiFixtureStage,images:[...document.querySelectorAll('img')].map(i=>({loaded:i.complete,width:i.naturalWidth,src:i.src})),dialogs:[...document.querySelectorAll('dialog')].map(d=>({open:d.open})),focused:document.activeElement?.outerHTML?.slice(0,300)}", 'args':[]})
            (packet/'diagnostic08.json').write_text(json.dumps(diagnostic,indent=2)+'\n')
            (packet/'failure-console08.json').write_text(json.dumps(request('/session/'+session+'/log', {'type':'browser'}),indent=2)+'\n')
        except Exception as diagnostic_error: result['diagnostic_error'] = str(diagnostic_error)
finally:
    if session:
        try: request('/session/'+session, method='DELETE')
        except Exception: pass
    for name, process in reversed(children):
        if process.poll() is None: process.terminate()
        try: result[name+'_exit'] = process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill(); result[name+'_exit'] = process.wait()
    for log in logs: log.close()
    if profile:
        try: shutil.rmtree(profile)
        except OSError as cleanup_error: result['cleanup_error'] = str(cleanup_error)
    (packet/'browser-gate08.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result))
raise SystemExit(0 if result.get('passed') else 1)
