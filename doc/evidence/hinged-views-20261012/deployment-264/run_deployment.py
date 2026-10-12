from pathlib import Path
import json,subprocess,sys
p=Path(__file__).resolve().parent
name=sys.argv[1];args=sys.argv[2:]
with (p/(name+('-'+args[0] if args else '')+'.log')).open('x') as f:
 r=subprocess.run([sys.executable,str(p/(name+'.py')),*args],stdout=f,stderr=subprocess.STDOUT)
with (p/(name+('-'+args[0] if args else '')+'.exit.json')).open('x') as f:json.dump({'exit':r.returncode,'args':args},f)
print(json.dumps({'exit':r.returncode,'args':args}),flush=True)
sys.exit(r.returncode)
