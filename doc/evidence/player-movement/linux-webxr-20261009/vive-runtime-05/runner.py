from pathlib import Path
import subprocess, os, tempfile, selectors, time, json, threading, hashlib, sys

root = Path('/home/yan/src/quod')
e = Path(sys.argv[1]).resolve()
e.mkdir(exist_ok=False)
runtime = root/'client/_build/webxr-linux/monado-build/src/xrt/targets/service/monado-service'
result = dict(simulated=False, runtime_exit=None, probe_exit=None,
              runtime_sha256=hashlib.sha256(runtime.read_bytes()).hexdigest())
(e/'probe.c').write_bytes(Path('/tmp/quod-vive-system-probe.c').read_bytes())
(e/'runner.py').write_bytes(Path(__file__).read_bytes())
with tempfile.TemporaryDirectory(prefix='quod-vive-') as tmp:
    p = Path(tmp)
    for name in ['runtime','config','cache','data']: (p/name).mkdir(mode=0o700)
    display = os.environ['WAYLAND_DISPLAY']
    source = Path(display) if Path(display).is_absolute() else Path(os.environ['XDG_RUNTIME_DIR'])/display
    (p/'runtime/wayland-display').symlink_to(source)
    env = os.environ.copy()
    for name in list(env):
        if name.startswith('SIMULATED_') or name.startswith('XRT_COMPOSITOR_FORCE_'): del env[name]
    env.update(XDG_RUNTIME_DIR=str(p/'runtime'), XDG_CONFIG_HOME=str(p/'config'),
               XDG_CACHE_HOME=str(p/'cache'), XDG_DATA_HOME=str(p/'data'),
               WAYLAND_DISPLAY='wayland-display', SIMULATED_ENABLE='0',
               STEAMVR_LH_ENABLE='1', LIGHTHOUSE_LOG='debug',
               STEAMVR_PATH='/home/yan/.local/share/Steam/steamapps/common/SteamVR',
               XRT_NO_STDIN='1', XR_RUNTIME_JSON=str(root/'client/_build/webxr-linux/monado-build/openxr_monado-dev.json'))
    if len(sys.argv)>2 and sys.argv[2]=='wayland-direct':
        env['XRT_COMPOSITOR_FORCE_WAYLAND_DIRECT']='1'
        result['display_backend']='wayland-direct'
    with (e/'runtime.log').open('wb') as log:
        child = subprocess.Popen([str(runtime)], env=env, cwd=tmp, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        result['runtime_pid'] = child.pid
        drain = None
        try:
            deadline = time.monotonic()+30
            received = b''
            with selectors.DefaultSelector() as sel:
                sel.register(child.stdout, selectors.EVENT_READ)
                while b'The Monado service has started.' not in received:
                    remain = deadline-time.monotonic()
                    if remain<=0 or not sel.select(remain): raise RuntimeError('service startup notice deadline exceeded')
                    chunk = os.read(child.stdout.fileno(),65536)
                    if not chunk: raise RuntimeError('service exited before startup notice')
                    log.write(chunk); log.flush(); received += chunk
            # This notice only means the listener started. OpenXR below verifies system readiness.
            def copy():
                for line in child.stdout: log.write(line); log.flush()
            drain = threading.Thread(target=copy)
            drain.start()
            with (e/'probe.log').open('x') as out:
                r = subprocess.run(['/tmp/quod-vive-system-probe'], env=env, stdout=out, stderr=subprocess.STDOUT, timeout=45)
            result['probe_exit'] = r.returncode
        except Exception as error: result['error'] = str(error)
        finally:
            if child.poll() is None: child.terminate()
            try: result['runtime_exit'] = child.wait(timeout=15)
            except subprocess.TimeoutExpired:
                child.kill(); result['runtime_exit'] = child.wait(); result['forced_kill'] = True
            if drain: drain.join()
            child.stdout.close()
(e/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
print((e/'probe.log').read_text() if (e/'probe.log').exists() else '')
print((e/'runtime.log').read_text(errors='replace')[-18000:])
raise SystemExit(0 if result['probe_exit']==0 and result['runtime_exit']==0 else 1)
