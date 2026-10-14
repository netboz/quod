#!/usr/bin/env python3
"""Run the native Linux WebXR preflight using local, isolated build artifacts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import threading
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--evidence', type=Path, required=True, help='New directory for this run')
parser.add_argument('--browser', type=Path, help='Browser executable; defaults to official Chrome for Testing')
parser.add_argument('--driver', type=Path, help='Matching ChromeDriver executable')
parser.add_argument('--device', choices=['simulated', 'vive'], default='simulated',
                    help='Use simulated devices or the physical Vive through SteamVR Lighthouse')
parser.add_argument('--frames', type=int, default=120, help='Frames per immersive session')
args = parser.parse_args()
if args.frames < 1:
    parser.error('--frames must be positive')
root = Path(__file__).resolve().parents[2]
base = root / 'client/_build/webxr-linux'
runtime = base / 'monado-build/src/xrt/targets/service/monado-service'
manifest = base / 'monado-build/openxr_monado-dev.json'
chrome = (args.browser or base / 'chrome-testing/chrome-linux64/chrome').resolve()
driver = (args.driver or base / 'chrome-testing/chromedriver-linux64/chromedriver').resolve()
for artifact in [runtime, manifest, chrome, driver]:
    if not artifact.exists():
        parser.error(f'Missing build artifact: {artifact}')
args.evidence.mkdir(parents=True, exist_ok=False)

with tempfile.TemporaryDirectory(prefix='quod-webxr-') as temporary:
    state = Path(temporary)
    for name in ['runtime', 'config', 'cache', 'data']:
        (state / name).mkdir(mode=0o700)
    # Chrome needs Wayland/GBM on NVIDIA. Keep only the display socket shared.
    display = os.environ.get('WAYLAND_DISPLAY')
    if not display:
        raise SystemExit('The NVIDIA WebXR preflight requires a Wayland session')
    source = Path(display) if Path(display).is_absolute() else Path(os.environ['XDG_RUNTIME_DIR']) / display
    (state / 'runtime' / 'wayland-display').symlink_to(source)
    env = os.environ.copy()
    for name in list(env):
        if name.startswith('SIMULATED_') or name.startswith('XRT_COMPOSITOR_FORCE_'):
            del env[name]
    env.update(
        XDG_RUNTIME_DIR=str(state / 'runtime'), XDG_CONFIG_HOME=str(state / 'config'),
        XDG_CACHE_HOME=str(state / 'cache'), XDG_DATA_HOME=str(state / 'data'),
        WAYLAND_DISPLAY='wayland-display',
        XR_RUNTIME_JSON=str(manifest), XRT_NO_STDIN='1',
    )
    simulated = args.device == 'simulated'
    if simulated:
        env.update(GDK_BACKEND='x11', SDL_VIDEODRIVER='x11', SIMULATED_ENABLE='1',
                   SIMULATED_LEFT='simple', SIMULATED_RIGHT='simple',
                   STEAMVR_LH_ENABLE='0', XRT_COMPOSITOR_FORCE_XCB='1',
                   XRT_COMPOSITOR_SCALE_PERCENTAGE='50')
    else:
        env.update(SIMULATED_ENABLE='0', STEAMVR_LH_ENABLE='1',
                   XRT_COMPOSITOR_FORCE_WAYLAND_DIRECT='1')
    result = {'browser_exit': None, 'runtime_exit': None, 'simulated': simulated,
              'device': args.device, 'frames_per_session': args.frames,
              'runtime_sha256': hashlib.sha256(runtime.read_bytes()).hexdigest(),
              'browser': str(chrome), 'driver': str(driver)}
    with (args.evidence / 'runtime.log').open('x') as log:
        service = subprocess.Popen([str(runtime)], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        drain = None
        try:
            # The listener's startup notice permits client connection. It does not
            # prove headset/compositor readiness; the native WebXR test does that.
            # Use unbuffered reads so a buffered partial read cannot hide the notice.
            deadline = time.monotonic() + 30
            received = b''
            with selectors.DefaultSelector() as selector:
                selector.register(service.stdout, selectors.EVENT_READ)
                while b'The Monado service has started.' not in received:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0 or not selector.select(remaining):
                        raise RuntimeError('Monado startup deadline exceeded')
                    chunk = os.read(service.stdout.fileno(), 65536)
                    if not chunk:
                        raise RuntimeError('Monado exited before startup')
                    received += chunk
                    log.write(chunk.decode(errors='replace')); log.flush()

            def copy_output():
                for line in service.stdout:
                    log.write(line.decode(errors='replace')); log.flush()

            drain = threading.Thread(target=copy_output)
            drain.start()
            with (args.evidence / 'browser.log').open('x') as browser_log:
                browser = subprocess.run(
                    ['python3', str(root / 'client/test/linux-webxr-preflight.py'),
                     '--evidence', str(args.evidence.resolve()),
                     '--frames', str(args.frames),
                     '--browser', str(chrome), '--driver', str(driver)],
                    env=env, stdout=browser_log, stderr=subprocess.STDOUT, timeout=150,
                )
            result['browser_exit'] = browser.returncode
        except Exception as error:
            result['error'] = str(error)
        finally:
            if service.poll() is None:
                service.terminate()
            try:
                result['runtime_exit'] = service.wait(timeout=15)
            except subprocess.TimeoutExpired:
                service.kill()
                result['runtime_exit'] = service.wait()
            if drain:
                drain.join()
            service.stdout.close()
    (args.evidence / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result), flush=True)
    raise SystemExit(0 if result['browser_exit'] == 0 and result['runtime_exit'] == 0 else 1)
