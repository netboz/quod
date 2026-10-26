from pathlib import Path
import subprocess,sys,json,time
here=Path(__file__).resolve().parent
for phase in sys.argv[1:]:
    label="phase-"+phase
    with (here/(label+".intent.json")).open("x") as f:json.dump({"phase":phase},f)
    start=time.monotonic()
    result=subprocess.run([sys.executable,str(here/"deploy-fleet.py"),phase])
    with (here/(label+".exit.json")).open("x") as f:json.dump({"exit":result.returncode,"seconds":time.monotonic()-start},f)
    if result.returncode:raise SystemExit(result.returncode)
