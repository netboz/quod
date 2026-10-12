from pathlib import Path
import subprocess,json,sys
p=Path(__file__).resolve().parent
with (p/'gallery-core-install.log').open('x') as f:r=subprocess.run([sys.executable,str(p/'install_gallery_core.py')],stdout=f,stderr=subprocess.STDOUT)
(p/'gallery-core-install.exit.json').write_text(json.dumps({'exit':r.returncode})+'\n');print(r.returncode);sys.exit(r.returncode)
