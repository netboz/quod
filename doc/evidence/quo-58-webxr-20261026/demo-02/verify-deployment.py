from pathlib import Path
import subprocess,sys,json,time
here=Path(__file__).resolve().parent
steps=[('fleet-readiness-01',['fleet-probe.py','fleet-readiness-01']),('https',['verify-https.py']),('client',['verify-client.py'])]
for label,args in steps:
    start=time.monotonic()
    result=subprocess.run([sys.executable,str(here/args[0]),*args[1:]])
    with (here/('verification-'+label+'.exit.json')).open('x') as f:json.dump({'exit':result.returncode,'seconds':time.monotonic()-start},f)
    if result.returncode:raise SystemExit(result.returncode)
