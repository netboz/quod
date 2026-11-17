#!/usr/bin/env python3
"""Verify official archived packages and extract privately, without installation."""
import hashlib,json,os,subprocess,sys,urllib.request
from pathlib import Path
package,version=sys.argv[1:3]
base=Path('/home/yan/.cache/quod-m4-r2-artifacts/runtime')
name=f'{package}-{version}-x86_64.pkg.tar.zst'
target=base/(package+'-'+version);assert not target.exists()
record={'package':package,'version':version,'global_installation':False,'downloads':[],'commands':[]}
receipt=Path(__file__).resolve().parent/'inputs'/(package+'-'+version+'.json')
try:
    for suffix in ['', '.sig']:
        filename=name+suffix;url=f'https://archive.archlinux.org/packages/{package[0]}/{package}/{filename}'
        path=base/filename
        with urllib.request.urlopen(url,timeout=60) as response,path.open('xb') as output:
            while block:=response.read(1048576):output.write(block)
        record['downloads'].append({'url':url,'path':str(path),'bytes':path.stat().st_size,'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
    env=dict(os.environ,GNUPGHOME=str(base/'gnupg'));env.pop('LD_LIBRARY_PATH',None);env.pop('LD_PRELOAD',None)
    command=['gpgv','--status-fd','1','--keyring',str(base/'archlinux-keyring.gpg'),str(base/(name+'.sig')),str(base/name)]
    child=subprocess.run(command,env=env,capture_output=True,text=True)
    record['commands'].append({'command':command,'exit':child.returncode,'stdout':child.stdout,'stderr':child.stderr})
    assert child.returncode==0 and '[GNUPG:] VALIDSIG ' in child.stdout
    target.mkdir()
    command=['bsdtar','-xf',str(base/name),'-C',str(target)]
    child=subprocess.run(command,capture_output=True,text=True)
    record['commands'].append({'command':command,'exit':child.returncode,'stdout':child.stdout,'stderr':child.stderr});assert child.returncode==0
    record['passed']=True
finally:
    receipt.write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'package':package,'version':version,'signature_verified':record.get('passed',False),'path':str(target)}))
