#!/usr/bin/env python3
"""Read public certificate via the allocation owner, then use ordinary verified TLS."""
import hashlib
import json
import os
from pathlib import Path
import ssl
import subprocess
import urllib.request

out=Path(__file__).resolve().parent
command=['nomad','alloc','exec','-task','quod','e9a938d4-300c-a5b2-b225-17e08b92c477','cat','/quod/data/identity/client_tls.crt']
r=subprocess.run(command,env=dict(os.environ,NOMAD_ADDR='http://192.168.1.10:4646'),capture_output=True,check=True)
certificate=out/'inputs/candidate-public-certificate.pem'
certificate.write_text(ssl.DER_cert_to_PEM_cert(r.stdout))
context=ssl.create_default_context(cafile=str(certificate))
url='https://192.168.1.10:30519/api/ontologies/system'
with urllib.request.urlopen(url,context=context,timeout=15) as response:data=response.read()
a=json.loads(data)
(out/'catalogue.json').write_text(json.dumps(a,indent=2)+'\n')
print(json.dumps(dict(certificate_command=command,certificate_child_exit=r.returncode,certificate_der_sha256=hashlib.sha256(r.stdout).hexdigest(),url=url,hostname_verification=True,catalogue=a),indent=2))
