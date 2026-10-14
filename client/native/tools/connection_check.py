#!/usr/bin/env python3
"""Exercise the real native UI against an isolated TLS protocol fixture."""
import argparse
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--evidence", type=Path, required=True)
parser.add_argument("--onboarding", action="store_true")
args = parser.parse_args()
args.evidence.mkdir(parents=True, exist_ok=False)
root = Path(__file__).resolve().parents[3]
with tempfile.TemporaryDirectory(prefix="quod-native-tls-") as name:
    state = Path(name)
    cert, key, bundle = state / "ca.pem", state / "key.pem", state / "identity.json"
    with (args.evidence / "certificate.log").open("wb") as log:
        certificate = subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key), "-out", str(cert), "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost"], stdout=log, stderr=subprocess.STDOUT)
    if certificate.returncode:
        raise SystemExit(certificate.returncode)
    corpus = json.loads((root / "client/test/fixtures/native-contract/contracts.json").read_text())
    bundle.write_text(corpus["bundle"])
    with (args.evidence / "fixture.log").open("wb") as fixture_log:
        fixture = subprocess.Popen(["node", str(root / "client/native/tools/connection-fixture.mjs"), str(cert), str(key), "onboarding" if args.onboarding else "import"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=fixture_log)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(fixture.stdout, selectors.EVENT_READ)
                if not selector.select(15):
                    raise RuntimeError("TLS fixture startup deadline exceeded")
                port = json.loads(fixture.stdout.readline())["port"]
            env = os.environ.copy()
            env.update(QUOD_FIXTURE_PORT=str(port), QUOD_FIXTURE_CA=str(cert), QUOD_FIXTURE_BUNDLE=str(bundle), QUOD_FIXTURE_STATE=str(state / "identity"))
            exits = []
            outputs = []
            unchanged_restore = None
            if args.onboarding:
                with (args.evidence / "tls-rejections.log").open("wb") as log:
                    negative = subprocess.run([sys.executable, str(root / "client/native/tools/run.py"), "--headless", "--script", "res://tests/tls_rejections.gd"], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=20)
                negative_log = (args.evidence / "tls-rejections.log").read_text(errors="replace")
                negative_result = {"exit": negative.returncode, "pass": negative.returncode == 0 and "TLS_REJECTIONS_PASS" in negative_log and "SCRIPT ERROR:" not in negative_log}
                (args.evidence / "tls-rejections.json").write_text(json.dumps(negative_result, indent=2)+"\n")
                if not negative_result["pass"]:
                    raise RuntimeError("TLS rejection checks failed; see retained log")
            for cycle in (["create", "recover", "restore"] if args.onboarding else ["import"]):
                env["QUOD_FIXTURE_CYCLE"] = cycle
                saved_paths = [state / "identity/active.json", state / "identity-connection.cfg"]
                before = [p.stat().st_mtime_ns for p in saved_paths] if cycle == "restore" else None
                with (args.evidence / f"godot-{cycle}.log").open("wb") as log:
                    child = subprocess.run([sys.executable, str(root / "client/native/tools/run.py"), "--headless", "--script", "res://tests/onboarding.gd" if args.onboarding else "res://tests/connection.gd"], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=45)
                if before is not None:
                    unchanged_restore = before == [p.stat().st_mtime_ns for p in saved_paths]
                    if not unchanged_restore:
                        raise RuntimeError("Unchanged restore rewrote identity or settings")
                exits.append(child.returncode)
                outputs.append((args.evidence / f"godot-{cycle}.log").read_text(errors="replace"))
                if child.returncode or "ERROR:" in outputs[-1]:
                    break
            fixture.stdin.write(b"done\n"); fixture.stdin.flush()
            server_exit = fixture.wait(timeout=5)
            output = "\n".join(outputs)
            result = {"unchanged_restore": unchanged_restore, "godot_exits": exits, "fixture_exit": server_exit, "pass": all(code == 0 for code in exits) and len(exits) == (3 if args.onboarding else 1) and server_exit == 0 and "ERROR:" not in output and "PASS" in output}
            (args.evidence / "result.json").write_text(json.dumps(result, indent=2)+"\n")
            print(json.dumps(result))
            if not result["pass"]:
                print(output)
                raise SystemExit(1)
        except Exception as error:
            (args.evidence / "failure.json").write_text(json.dumps({"pass": False, "error": str(error)})+"\n")
            raise
        finally:
            if fixture.poll() is None:
                fixture.terminate(); fixture.wait(timeout=5)
