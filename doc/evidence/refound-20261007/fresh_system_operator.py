#!/usr/bin/env python3
from pathlib import Path
import base64, hashlib, json, re, subprocess, sys, time
OUT = Path('/tmp/quod-candidate-refound-252-20261007-v2')
ALLOC = '4098bae6-82e8-e067-69e1-73e97e97b102'
NOMAD = 'http://192.168.1.10:4646'
BEAM = OUT / 'quod_fresh_systems.beam'

def save_new(path, value):
    with path.open('x') as f:
        json.dump(value, f, indent=2)
        f.write('\n')

def run(label, expression):
    encoded = 'binary_to_list(base64:encode(iolist_to_binary(json:encode(begin ' + expression + ' end)))).'
    command = ['nomad','alloc','exec','-i=false','-t=false','-address='+NOMAD,'-task','quod',ALLOC,
               '/opt/quod/bin/quod','eval',encoded]
    save_new(OUT/(label+'.intent.json'), {'allocation':ALLOC,'expression':expression,'command_argv':command})
    started=time.monotonic()
    result=subprocess.run(command, capture_output=True, text=True)
    save_new(OUT/(label+'.exit.json'), {'exit':result.returncode,'seconds':time.monotonic()-started})
    (OUT/(label+'.stdout')).write_text(result.stdout)
    (OUT/(label+'.stderr')).write_text(result.stderr)
    if result.returncode:
        raise SystemExit(result.returncode)
    wire=json.loads(result.stdout)
    if isinstance(wire,list):
        assert all(type(c) is int and 0 <= c < 128 for c in wire)
        wire=bytes(wire).decode('ascii')
    value=json.loads(base64.b64decode(wire,validate=True))
    save_new(OUT/(label+'.json'), value)
    print(json.dumps(value,indent=2))
    return value

def anchors():
    p=OUT/'anchors.json'
    return json.loads(p.read_text()) if p.exists() else {}

def anchor_expr(name):
    value=anchors()[name]
    assert re.fullmatch('[0-9A-F]{64}',value)
    return 'binary:decode_hex(<<"'+value+'">>)'

def dep(predicate,name):
    return '{'+predicate+',<<"quod:'+name+'">>,'+anchor_expr(name)+'}'

def deps(name):
    if name=='environment:eidolons': return [dep('environment_vocabulary','environment')]
    if name=='material': return [dep('measure_vocabulary','measure')]
    if name=='material:eidolons': return [dep('material_vocabulary','material')]
    if name=='modelling': return [dep('rendering_vocabulary','rendering')]
    if name=='lobby': return [
        dep('modelling_vocabulary','modelling'),
        dep('material_eidolons','material:eidolons'),
        dep('environment_vocabulary','environment'),
        dep('environment_eidolons','environment:eidolons'),
        dep('gui_vocabulary','gui')]
    if name=='signup': return [dep('lobby_vocabulary','lobby')]
    return []

def quoted_name(name):
    assert re.fullmatch('[a-z_]+(?::[a-z_]+)?',name)
    return '<<"'+name+'">>'

phase=sys.argv[1]
if phase=='load':
    data=BEAM.read_bytes(); digest=hashlib.sha256(data).hexdigest().upper(); payload=base64.b64encode(data).decode()
    run('load-helper','{module,quod_fresh_systems}=code:load_binary(quod_fresh_systems,"'+digest+'",base64:decode(<<"'+payload+'">>)), #{loaded => true}')
elif phase=='reload-diagnostic-helper':
    data=BEAM.read_bytes(); digest=hashlib.sha256(data).hexdigest().upper(); payload=base64.b64encode(data).decode()
    run('reload-diagnostic-helper','{module,quod_fresh_systems}=code:load_binary(quod_fresh_systems,"'+digest+'",base64:decode(<<"'+payload+'">>)), #{loaded => true}')
elif phase=='root-info':
    run('root-info','{ok,NodeKey}=application:get_env(quod,node_pubkey), #{root_anchor => binary:encode_hex(quod_simplex:genesis_hash(<<"quod:root">>)), node_pubkey => binary:encode_hex(NodeKey)}')
elif phase=='found':
    name=sys.argv[2]; label='found-'+name.replace(':','-')
    value=run(label,'quod_fresh_systems:found('+quoted_name(name)+',['+','.join(deps(name))+'])')
    current=anchors(); assert name not in current
    current[name]=value['anchor']; (OUT/'anchors.json').write_text(json.dumps(current,indent=2)+'\n')
elif phase=='publish':
    name=sys.argv[2]; run('publish-'+name.replace(':','-'),'quod_fresh_systems:publish('+quoted_name(name)+','+anchor_expr(name)+')')
elif phase=='policy-node':
    run('policy-node','quod_fresh_systems:add_policies([{<<"quod:node">>,'+anchor_expr('node')+'}])')
elif phase=='wait-principal':
    run('wait-principal','quod_fresh_systems:wait_principal()')
elif phase=='request-enrollment':
    run('request-enrollment','ok=quod_namespace_manager:enroll_node(), timer:sleep(250), quod_namespace_manager:stats()')
elif phase=='request-enrollment-02':
    run('request-enrollment-02','ok=quod_namespace_manager:enroll_node(), timer:sleep(250), quod_namespace_manager:stats()')
elif phase=='diagnose-enrollment':
    run('diagnose-enrollment','quod_fresh_systems:diagnose_enrollment()')
elif phase=='enrollment-evidence':
    run('enrollment-evidence','quod_fresh_systems:enrollment_evidence()')
elif phase=='wait-principal-02':
    run('wait-principal-02','quod_fresh_systems:wait_principal()')
elif phase=='policy-apps':
    run('policy-apps','quod_fresh_systems:add_policies([{<<"quod:lobby">>,'+anchor_expr('lobby')+'},{<<"quod:signup">>,'+anchor_expr('signup')+'}])')
elif phase=='delegate-signup':
    run('delegate-signup','quod_fresh_systems:delegate_signup('+anchor_expr('signup')+')')
elif phase=='catalog':
    run('catalog','quod_fresh_systems:catalog()')
elif phase=='final-gate':
    run('final-gate','quod_fresh_systems:final_gate()')
else:
    raise SystemExit('unknown phase')
