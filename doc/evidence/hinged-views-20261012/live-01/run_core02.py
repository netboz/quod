from pathlib import Path
import subprocess,json,sys
p=Path(__file__).resolve().parent
with (p/'core02-install.log').open('x') as f:r=subprocess.run([sys.executable,str(p/'install_core02.py')],stdout=f,stderr=subprocess.STDOUT)
(p/'core02-install.exit.json').write_text(json.dumps({'exit':r.returncode})+'\n');print(r.returncode);sys.exit(r.returncode)
