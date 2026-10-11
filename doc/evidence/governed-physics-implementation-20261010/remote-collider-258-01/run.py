from pathlib import Path
import base64, hashlib, json, os, subprocess, time

out = Path(__file__).resolve().parent
deployment = out.parent/'quod27-release-258/deployment/refound'
fleet = json.loads((deployment/'fleet-probe.json').read_text())
assert fleet['passed'] and len(fleet['allocations']) == 8
assert all(r['probe']['version'] == '0.7.258' for r in fleet['allocations'])
nodes = sorted(fleet['allocations'],key=lambda r:r['name'])[:2]
assert nodes[0]['node'] != nodes[1]['node']
execution = out/'execution'; execution.mkdir()
world_ns = 'acceptance:physics:258:gallery'
source_ns = 'acceptance:physics:258:objects'
nomad = 'http://192.168.1.10:4646'

def binary(value):
    if value.isascii():
        return '<<'+json.dumps(value)+'>>'
    return '<<'+','.join(map(str,value.encode()))+'>>'

def save(path,value):
    with path.open('x') as f: json.dump(value,f,indent=2); f.write('\n')

def rpc(node,label,expression):
    command = ['nomad','alloc','exec','-i=false','-t=false','-address='+nomad,
        '-task','quod',nodes[node]['allocation'],'/opt/quod/bin/quod','eval',
        'binary_to_list(base64:encode(iolist_to_binary(json:encode(begin '+expression+' end)))).']
    assert max(len(arg.encode()) for arg in command) < 128*1024, 'exec argument too large'
    save(execution/(label+'.intent.json'),{'node':nodes[node],'expression':expression})
    start=time.monotonic()
    result=subprocess.run(command,capture_output=True,text=True)
    (execution/(label+'.stdout')).write_text(result.stdout)
    (execution/(label+'.stderr')).write_text(result.stderr)
    save(execution/(label+'.exit.json'),{'exit':result.returncode,'seconds':time.monotonic()-start})
    assert result.returncode == 0, label+' failed; inspect original result, never resubmit'
    wire=json.loads(result.stdout)
    if isinstance(wire,list): wire=bytes(wire).decode('ascii')
    answer=json.loads(base64.b64decode(wire,validate=True))
    save(execution/(label+'.json'),answer)
    print(label+' completed',flush=True)
    return answer

def call(node,label,function,*args):
    return rpc(node,label,'quod_remote_collider_evidence:'+function+'('+','.join(args)+')')

def operation(): return binary(os.urandom(32).hex().upper())

def signed_args(request): return [binary(request['bytes']),binary(request['signature'])]

def expect_commit(result,label):
    assert result['committed'],label+' did not commit; resolve the retained original identity'

try:
    beam=(out/'quod_remote_collider_evidence.beam').read_bytes()
    digest=hashlib.sha256(beam).hexdigest()
    save(execution/'scope.json',{'world':world_ns,'source':source_ns,'allocations':nodes,
        'root_anchor':nodes[0]['probe']['root_anchor'],'helper_sha256':digest,
        'purpose':'Real remote signed collider transition and unchanged-work measurement; not personal desktop acceptance'})
    for node in (0,1):
        rpc(node,'load-'+str(node),'{module,quod_remote_collider_evidence}=code:load_binary('
            'quod_remote_collider_evidence,'+json.dumps(digest)+',base64:decode('
            +binary(base64.b64encode(beam).decode())+')), #{loaded => true}')
    host=call(0,'physics-host','node')['reference']
    editor=call(1,'source-editor','node')['reference']
    world=call(0,'found-world','found_world',binary(world_ns),binary(editor))
    source=call(1,'found-source','found_source',binary(source_ns),binary(world_ns),
        binary(world['anchor']),binary(host))
    initial=call(0,'nonphysical-baseline','world',binary(world_ns))
    assert initial['worlds'] == []
    request=call(0,'prepare-key-request','preparation',binary(world_ns),binary(world['anchor']),operation())
    prepared=call(0,'prepare-key-submit','submit',*signed_args(request))
    assert 'read_encoded' in prepared
    request=call(0,'activation-request','activation',binary(world_ns),binary(world['anchor']),
        binary(source_ns),binary(source['anchor']),binary(editor),
        '#{key_values => '+binary(prepared['read_encoded'])+',operation => '+operation()+'}')
    expect_commit(call(0,'activation-submit','submit',*signed_args(request)),'activation')
    call(0,'activation-installed','installed',binary(world_ns),'1')
    call(0,'activation-receipt','receipt',*signed_args(request))
    reader = None
    context_to_review = []
    for kind,structure in [('admission',2),('unrelated',2),('edit',3),('withdrawal',4)]:
        request=call(1,kind+'-request','source_operation',binary(source_ns),binary(world_ns),
            binary(world['anchor']),kind,operation())
        measured=call(0,kind+'-measured','observed_submit',binary(world_ns),binary(source_ns),
            binary(source['anchor']),binary(reader) if reader else 'none',
            str(structure),*signed_args(request))
        expect_commit(measured['outcome'],kind)
        before=measured['before']['worlds'][0]
        after=measured['after_change']['worlds'][0]
        assert before['pid'] == after['pid'] and before['fence'] == after['fence']
        assert after['counters']['navigation_ready']
        expected_installs=0 if kind == 'unrelated' else 1
        assert after['counters']['installs']-before['counters']['installs'] == expected_installs
        expected_bodies=[{'body':1,'revision':1}]
        if kind != 'withdrawal': expected_bodies.append({'body':2,'revision':3 if kind == 'edit' else 2})
        assert after['body_revisions'] == expected_bodies
        reader=measured['source_notice']['reader']
        call(1,kind+'-receipt','receipt',*signed_args(request))
        repeat=call(0,kind+'-unchanged','unchanged',binary(world_ns),binary(reader))
        resource_work={k:v for k,v in repeat['work'].items() if 'quod_physics_native,step' not in k}
        assert resource_work == {},kind+' unchanged checks performed resource work'
        assert repeat['before']['worlds'][0]['counters']['installs'] == repeat['after_checks']['worlds'][0]['counters']['installs']
        if repeat['node_work']: context_to_review.append(kind)
        if kind == 'unrelated':
            assert not any(('quod_physics_native' in key and 'quod_physics_native,step' not in key) or 'quod_ledger_store,fold' in key
                or 'quod_foreign_projection,start_monitor' in key for key in measured['work']), measured['work']
        if kind == 'edit':
            assert '{ball,0.6}' in measured['after_change']['worlds'][0]['bodies']
        if kind == 'withdrawal':
            assert '{ball,0.6}' not in measured['after_change']['worlds'][0]['bodies']
    for node in (0,1):
        rpc(node,'unload-'+str(node),'true=code:delete(quod_remote_collider_evidence),'
            'true=code:soft_purge(quod_remote_collider_evidence),#{unloaded => true}')
    save(execution/'PASSED.json',{'passed':True,'world':world,'source':source,
        'remote_nodes':True,'repeat_checks':80,'personal_desktop_acceptance':False,
        'node_context_requires_attribution':context_to_review})
except BaseException as error:
    save(execution/'STOP.json',{'reason':str(error),'kind':type(error).__name__,
        'rule':'Inspect recorded original operations. Do not rerun this campaign.'})
    raise
