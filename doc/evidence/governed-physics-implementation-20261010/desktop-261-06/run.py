from pathlib import Path
import base64,json,os,re,selectors,subprocess,threading,time,urllib.request,urllib.error
root=Path.cwd(); evidence=Path(__file__).resolve().parent
base=root/'client/_build/webxr-linux/chrome-testing'
chrome=base/'chrome-linux64/chrome';driver_path=base/'chromedriver-linux64/chromedriver'
session_id=None;code=1
with (evidence / 'chromedriver.log').open('x') as log:
    driver = subprocess.Popen([str(driver_path), '--port=0', '--enable-chrome-logs'],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              env={k:v for k,v in os.environ.items() if k not in {"LD_LIBRARY_PATH", "CHROME_DESKTOP"}})
    drain = None
    try:
        received = b''
        deadline = time.monotonic() + 15
        with selectors.DefaultSelector() as selector:
            selector.register(driver.stdout, selectors.EVENT_READ)
            match = None
            while not match:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise RuntimeError('ChromeDriver startup deadline exceeded')
                chunk = os.read(driver.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError('ChromeDriver exited before startup')
                received += chunk
                log.write(chunk.decode(errors='replace')); log.flush()
                match = re.search(rb'started successfully on port (\d+)', received)
        endpoint = f'http://127.0.0.1:{match[1].decode()}'

        def copy_output():
            for line in driver.stdout:
                log.write(line.decode(errors='replace')); log.flush()

        drain = threading.Thread(target=copy_output)
        drain.start()

        def request(method, path, body=None):
            data = json.dumps(body).encode() if body is not None else None
            req = urllib.request.Request(endpoint + path, data=data, method=method,
                                         headers={'Content-Type': 'application/json'})
            try:
                response = urllib.request.urlopen(req, timeout=100)
            except urllib.error.HTTPError as error:
                raise RuntimeError(error.read().decode()) from error
            value = json.load(response)['value']
            if isinstance(value, dict) and 'error' in value:
                raise RuntimeError(json.dumps(value))
            return value

        created = request('POST', '/session', {'capabilities': {'alwaysMatch': {
            'browserName': 'chrome', 'acceptInsecureCerts': True,
            'goog:loggingPrefs': {'browser': 'ALL', 'performance': 'ALL'},
            'goog:chromeOptions': {'binary': str(chrome), 'args': [
                '--ozone-platform=wayland', '--no-first-run', '--no-default-browser-check',
                '--window-size=1200,800', '--user-data-dir=' + str(root/'_build/quod27-desktop-259-03/profile')
            ]},
        }}})
        session_id = created['sessionId']; prefix = '/session/' + session_id
        def command(path, body=None):return request('POST', prefix+path, body or {})
        command('/timeouts', {'script': 10000, 'pageLoad': 30000})
        command('/url', {'url': 'https://192.168.1.10:30519/'})
        def inspect():
            state=command('/execute/sync', {'script':'return {url:location.href,title:document.title,text:document.body.innerText,buttons:[...document.querySelectorAll("button")].map(x=>({text:x.innerText,disabled:x.disabled})),inputs:[...document.querySelectorAll("input")].map(x=>({type:x.type,placeholder:x.placeholder}))}', 'args':[]})
            print(json.dumps({'event':'page','state':state}),flush=True)
            return state
        (evidence/'session.json').write_text(json.dumps({'endpoint':endpoint,'session':session_id,'browser':str(chrome)},indent=2)+'\n')
        command('/execute/async', {'script': 'const done=arguments[0]; const ready=()=>!!document.querySelector("canvas.world-canvas") && !document.body.innerText.includes("Opening your"); if(ready()){done(true)}else{const m=new MutationObserver(()=>{if(ready()){m.disconnect();done(true)}});m.observe(document.body,{childList:true,subtree:true,characterData:true})}', 'args':[]})
        (evidence/'initial-page.json').write_text(json.dumps(inspect(),indent=2)+'\n')
        print(json.dumps({'event':'ready','endpoint':endpoint,'session':session_id}),flush=True)
        import sys
        for line in sys.stdin:
            try:
                action=json.loads(line)
                if action['action']=='quit':break
                if action['action']=='inspect':inspect()
                elif action['action']=='evaluate':print(json.dumps(command('/execute/sync',{'script':action['script'],'args':action.get('args',[])})),flush=True)
                elif action['action']=='logs':print(json.dumps(command('/log',{'type':'browser'})),flush=True)
                elif action['action']=='screenshot':
                    name=action['name'];assert name.isascii() and name.replace('-','').isalnum()
                    (evidence/(name+'.png')).write_bytes(base64.b64decode(request('GET',prefix+'/screenshot')))
                    print(json.dumps({'screenshot':name}),flush=True)
            except Exception as error:print(json.dumps({'action_error':str(error)}),flush=True)
        code = 0
    except Exception as error:
        print(json.dumps({'event': 'harness-failed', 'reason': str(error)}), flush=True)
    finally:
        if session_id:
            try:
                browser_log = command('/log', {'type': 'browser'})
                (evidence / 'console-after.json').write_text(json.dumps(browser_log, indent=2) + '\n')
                request('DELETE', prefix)
            except Exception as error:
                print(json.dumps({'event': 'cleanup-failed', 'reason': str(error)}), flush=True)
                code = 1
        if driver.poll() is None:
            driver.terminate()
        driver.wait(timeout=15)
        if drain:
            drain.join()
        driver.stdout.close()

raise SystemExit(code)
