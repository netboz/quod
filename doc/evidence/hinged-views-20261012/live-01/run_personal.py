from pathlib import Path
import subprocess,json,sys
p=Path(__file__).resolve().parent
with (p/'personal-authored-install.log').open('x') as f:r=subprocess.run([sys.executable,str(p/'install_personal.py')],stdout=f,stderr=subprocess.STDOUT)
(p/'personal-authored-install.exit.json').write_text(json.dumps({'exit':r.returncode})+'\n');print(r.returncode);sys.exit(r.returncode)
