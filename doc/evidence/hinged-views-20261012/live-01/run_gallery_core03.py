from pathlib import Path
import subprocess,json,sys
p=Path(__file__).resolve().parent
with (p/'gallery-core03-install.log').open('x') as f:r=subprocess.run([sys.executable,str(p/'install_gallery_core03.py')],stdout=f,stderr=subprocess.STDOUT)
(p/'gallery-core03-install.exit.json').write_text(json.dumps({'exit':r.returncode})+'\n');print(r.returncode);sys.exit(r.returncode)
