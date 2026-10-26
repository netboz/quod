"""Temporary trust for one verified test-fleet certificate; preserve other rows."""
from pathlib import Path
import hashlib, json, ssl, subprocess, sys

root=Path('/home/yan/src/quod')
evidence=Path(__file__).resolve().parent
state=root/'_build/quo-58-webxr-20261026/demo-01/vive-live-01'
deployment=root/'_build/quo-58-webxr-20261026/demo-01/deployment'
verified=json.loads((root/'doc/evidence/quo-58-webxr-20261026/demo-01/https-verified.json').read_text())
certificate=deployment/'client-public-certificate.pem'
nickname='quod-xr-demo01-vive-live01'
database='sql:/home/yan/.pki/nssdb'
action=sys.argv[1]
assert action in ['install','remove']
assert verified['normal_hostname_verification'] and verified['exact_public_certificate_match']

def fingerprint(pem):
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem)).hexdigest()

assert fingerprint(certificate.read_text())==verified['certificate_sha256']

def run(arguments):
    return subprocess.run(['certutil',*arguments,'-d',database],capture_output=True,text=True)

def listing(label):
    result=run(['-L']);assert result.returncode==0,result.stderr
    with (state/('trust-'+label+'.txt')).open('x') as f:f.write(result.stdout)
    return result.stdout.splitlines()

def current():
    result=run(['-L','-n',nickname,'-a'])
    if result.returncode==0:return fingerprint(result.stdout)
    assert ('Could not find cert: '+nickname) in result.stderr and \
           'PR_FILE_NOT_FOUND_ERROR' in result.stderr,result.stderr
    return None

before=listing(action+'-before')
existing=current()
if action=='install':
    assert existing is None,'Campaign nickname is already present; no overwrite'
    arguments=['-A','-n',nickname,'-t','P,,','-i',str(certificate)]
else:
    installed=json.loads((state/'trust-install.json').read_text())
    assert installed['certificate_sha256']==verified['certificate_sha256']
    assert existing==verified['certificate_sha256'],'Never remove another certificate'
    arguments=['-D','-n',nickname]
with (state/('trust-'+action+'-intent.json')).open('x') as f:
    json.dump({'action':action,'nickname':nickname,'database':database,
               'certificate_sha256':verified['certificate_sha256']},f,indent=2)
result=run(arguments)
with (state/('trust-'+action+'-command.json')).open('x') as f:
    json.dump({'exit':result.returncode,'stdout':result.stdout,'stderr':result.stderr},f,indent=2)
assert result.returncode==0,result.stderr
after=listing(action+'-after')
assert [line for line in before if nickname not in line]==[
    line for line in after if nickname not in line],'Another trust row changed'
assert current()==(verified['certificate_sha256'] if action=='install' else None)
receipt={'action':action,'exit':0,'certificate_sha256':verified['certificate_sha256'],
         'nickname':nickname,'trust':'exact TLS server leaf','other_trust_rows_unchanged':True,
         'hostname_checks_disabled':False}
with (state/('trust-'+action+'.json')).open('x') as f:json.dump(receipt,f,indent=2)
with (evidence/('trust-'+action+'.json')).open('x') as f:json.dump(receipt,f,indent=2)
print(json.dumps(receipt),flush=True)
