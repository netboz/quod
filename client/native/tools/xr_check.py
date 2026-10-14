#!/usr/bin/env python3
"""Qualify two Godot OpenXR sessions using the existing private Monado build."""
import argparse
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import threading
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--evidence", type=Path, required=True)
args = parser.parse_args()
args.evidence = args.evidence.resolve()
args.evidence.mkdir(parents=True, exist_ok=False)
root = Path(__file__).resolve().parents[3]
runtime = root / "client/_build/webxr-linux/monado-build"
service_binary = runtime / "src/xrt/targets/service/monado-service"
manifest = runtime / "openxr_monado-dev.json"
if not service_binary.exists() or not manifest.exists():
    parser.error("The existing private Monado build is required")
with tempfile.TemporaryDirectory(prefix="quod-godot-xr-") as temporary:
    state = Path(temporary)
    for folder in ["runtime", "config"]:
        (state / folder).mkdir(mode=0o700)
    env = os.environ.copy()
    # The owned runtime uses X11, preserving the host's display credentials.
    env.update(XDG_RUNTIME_DIR=str(state / "runtime"), XDG_CONFIG_HOME=str(state / "config"),
               XR_RUNTIME_JSON=str(manifest), SIMULATED_ENABLE="1", SIMULATED_LEFT="simple",
               SIMULATED_RIGHT="simple", SDL_VIDEODRIVER="x11", XRT_COMPOSITOR_FORCE_XCB="1",
               XRT_COMPOSITOR_SCALE_PERCENTAGE="50", XRT_NO_STDIN="1")
    # Keep the existing Wayland display reachable for Godot's window.
    display = env.get("WAYLAND_DISPLAY")
    if display:
        source = Path(display) if Path(display).is_absolute() else Path(os.environ["XDG_RUNTIME_DIR"]) / display
        (state / "runtime" / "wayland-display").symlink_to(source)
        env["WAYLAND_DISPLAY"] = "wayland-display"
    result = {"simulated": True, "sessions": [], "runtime_exit": None}
    with (args.evidence / "runtime.log").open("wb") as log:
        service = subprocess.Popen([str(service_binary)], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        drain = None
        try:
            deadline = time.monotonic() + 30
            received = b""
            with selectors.DefaultSelector() as selector:
                selector.register(service.stdout, selectors.EVENT_READ)
                while b"The Monado service has started." not in received:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0 or not selector.select(remaining):
                        raise RuntimeError("Monado startup deadline exceeded")
                    chunk = os.read(service.stdout.fileno(), 65536)
                    if not chunk:
                        raise RuntimeError("Monado exited before readiness")
                    received += chunk
                    log.write(chunk); log.flush()
            def copy_output():
                for line in service.stdout:
                    log.write(line); log.flush()
            drain = threading.Thread(target=copy_output)
            drain.start()
            for cycle in [1, 2]:
                report = args.evidence / f"session-{cycle}.json"
                env.update(QUOD_XR_REPORT=str(report), QUOD_XR_SCREENSHOT=str(args.evidence / f"session-{cycle}.png"))
                with (args.evidence / f"session-{cycle}.log").open("wb") as output:
                    child = subprocess.run([sys.executable, str(root / "client/native/tools/run.py"), "--xr", "--silent", "--script", "res://tests/xr.gd"], env=env, stdout=output, stderr=subprocess.STDOUT, timeout=40)
                diagnostics = [line for line in (args.evidence / f"session-{cycle}.log").read_text().splitlines() if "ERROR" in line or "isn't part of an action set" in line]
                item = {"exit": child.returncode, "diagnostics": diagnostics, "report": json.loads(report.read_text()) if report.exists() else None}
                result["sessions"].append(item)
                if child.returncode or item["report"] is None or not item["report"]["pass"]:
                    break
        except Exception as error:
            result["error"] = str(error)
        finally:
            if service.poll() is None:
                service.terminate()
            result["runtime_exit"] = service.wait(timeout=15)
            if drain:
                drain.join(timeout=5)
    result["pass"] = len(result["sessions"]) == 2 and all(s["exit"] == 0 and not s["diagnostics"] and s["report"]["pass"] for s in result["sessions"]) and result["runtime_exit"] == 0
    (args.evidence / "result.json").write_text(json.dumps(result, indent=2)+"\n")
    print(json.dumps({"pass": result["pass"], "session_exits": [s["exit"] for s in result["sessions"]], "runtime_exit": result["runtime_exit"], "error": result.get("error")}))
    sys.exit(0 if result["pass"] else 1)
