#!/usr/bin/env python3
from pathlib import Path
import base64
import json
import subprocess
import sys
import time
import urllib.request

out = Path('/home/yan/src/quod/_build/world-library-20261016/deployment-02/refound')
address = 'http://192.168.1.10:4646'
job = 'quod-finality-candidate-v6-20260926'
scope = json.loads((out / 'scope.json').read_text())
label = sys.argv[1] if len(sys.argv) == 2 else 'fleet-probe'
assert label in ['fleet-probe', 'fleet-probe-after-desktop']
record = out / (label + '.json')
assert not record.exists()
deployment_id = json.loads((out / 'deployment-success.json').read_text())['ID']
root_anchor = json.loads((out / 'root-info.json').read_text())['root_anchor']
image = scope['new_image']
volume_family = scope['new_family']

def get(path):
    return json.loads(urllib.request.urlopen(address + path).read())

candidate = get('/v1/job/' + job)
main = get('/v1/job/quod')
deployment = get('/v1/deployment/' + deployment_id)
allocations = [a for a in get('/v1/job/' + job + '/allocations')
               if a['ClientStatus'] == 'running' and a['DesiredStatus'] == 'run'
               and a['TaskGroup'] == 'quod-node']
assert len(allocations) == 8, len(allocations)

expression = '''
{ok,Height,Descriptors,Rejected}=quod_system_ontology:catalog(),
NotReady=[{Ns,State} || #{namespace := Ns} <- Descriptors,
                         State <- [quod_ontology:local_state(Ns)], State =/= {ok,ready}],
Principal=case quod_node_actor:principal() of
  {ok,{agent,Blob}=P} ->
    {ok,#{identity := {ActorNs,ActorAnchor},reference := Ref}}=quod_agent_ref:decode(Blob),
    {ok,Dir}=application:get_env(quod,identity_dir),
    Pointer=case quod_identity:load_node_actor_pointer(Dir) of {ok,Blob}->stored; _->not_stored end,
    Hosting=case quod_prolog:prove_ro(ActorNs,{hosts_ontology,Ref,ActorNs,ActorAnchor,discoverable}) of
      {ok,[_],_}->committed; _->missing end,
    {ok,Ref}=quod_agent_ref:materialize_principal(P),
    #{status => available,pointer => Pointer,self_hosting => Hosting,
      namespace => ActorNs,anchor => binary:encode_hex(ActorAnchor)};
  _ -> #{status => unavailable}
end,
Profiles=maps:from_list([begin
  Expected=case Ns of <<"quod:gui">>->[quod_agent_predicates,quod_gui_predicates]; _->[quod_agent_predicates] end,
  {ok,[#{'Manifest' := Manifest}],_}=quod_prolog:prove_ro(Ns,{external_predicate_modules,{'Manifest'}}),
  Expected=[M || {M,<<_:256>>} <- Manifest],
  {Ns,Expected}
end || #{namespace := Ns} <- Descriptors]),
RootStats=quod_simplex:stats(<<"quod:root">>),
{CustodyCount,CustodyBytes}=quod_effect_journal:limits(),
{ok,[#{'Count' := CustodyCount,'PreparedBytes' := CustodyBytes}],_}=
  quod_prolog:prove_ro(<<"quod:root">>,
    {effect_custody_limits,{'Count'},{'PreparedBytes'}}),
#{version => list_to_binary(element(2,application:get_key(quod,vsn))),
  custody_limits => #{count => CustodyCount,prepared_bytes => CustodyBytes},
  root_anchor => binary:encode_hex(quod_simplex:genesis_hash(<<"quod:root">>)),
  root_state => case quod_ontology:local_state(<<"quod:root">>) of
    {ok,S}->S; Other->iolist_to_binary(io_lib:format("~0p",[Other])) end,
  root_committee_size => length(quod_simplex:committee(<<"quod:root">>)),
  root_committed => maps:get(committed,RootStats),
  root_applied => maps:get(last_applied,RootStats),
  module_profiles => Profiles,catalogue_height => Height,catalogue_count => length(Descriptors),
  rejected_count => map_size(Rejected),not_ready => NotReady,
  manager => quod_namespace_manager:stats(),principal => Principal,
  vault_ready => is_pid(quod_reg:where({agent_vault,node})),
  vault_provider_disabled => maps:get(provider,element(2,application:get_env(quod,agent_vault))) =:= none}
'''.strip()
encoded = 'binary_to_list(base64:encode(iolist_to_binary(json:encode(begin ' + expression + ' end)))).'

results = []
started = time.monotonic()
for alloc in sorted(allocations, key=lambda a: a['Name']):
    command = ['nomad','alloc','exec','-i=false','-t=false','-address='+address,
               '-task','quod',alloc['ID'],'/opt/quod/bin/quod','eval',encoded]
    result = subprocess.run(command, capture_output=True, text=True)
    row = {'allocation': alloc['ID'], 'name': alloc['Name'], 'node': alloc['NodeName'],
           'restarts': alloc['TaskStates']['quod']['Restarts'], 'exit': result.returncode}
    if result.returncode:
        row['stderr'] = result.stderr
    else:
        wire = json.loads(result.stdout)
        if isinstance(wire, list):
            wire = bytes(wire).decode('ascii')
        row['probe'] = json.loads(base64.b64decode(wire, validate=True))
    results.append(row)
    print(json.dumps(row), flush=True)

task_group = candidate['TaskGroups'][0]
task_images = sorted({t.get('Config', {}).get('image') for t in task_group['Tasks']
                      if t.get('Config', {}).get('image')})
document = {
    'passed': False,
    'job': job,
    'job_version': candidate['Version'],
    'job_modify_index': candidate['JobModifyIndex'],
    'deployment': {'id': deployment_id, 'status': deployment['Status'],
                   'description': deployment['StatusDescription']},
    'image': image,
    'task_images': task_images,
    'volume_family': task_group['Volumes']['quod-data']['Source'],
    'main_job': {'version': main['Version'], 'job_modify_index': main['JobModifyIndex']},
    'allocations': results,
    'seconds': time.monotonic() - started,
}
record.write_text(json.dumps(document, indent=2) + '\n')

assert candidate['Version'] == scope['candidate_version'] + 2
assert deployment['Status'] == 'successful'
assert set(task_images) == {image}
assert task_group['Volumes']['quod-data']['Source'] == volume_family
assert main['Version'] == scope['main_version'] and main['JobModifyIndex'] == scope['main_modify_index']
frontend=get('/v1/job/quod27-client-30519')
assert frontend['Version']==1 and frontend['JobModifyIndex']==846370
assert all(r['exit'] == 0 and r['restarts'] == 0 for r in results)
for row in results:
    p = row['probe']
    assert p['version'] == '0.7.273'
    assert p['module_profiles']['quod:gui'] == ['quod_agent_predicates','quod_gui_predicates']
    assert len(p['module_profiles']) == 18
    assert p['custody_limits'] == {'count':64,'prepared_bytes':'unlimited'}
    assert p['vault_ready'] and p['vault_provider_disabled']
    assert p['root_anchor'] == root_anchor
    assert p['root_state'] == 'ready'
    assert p['root_committed'] == p['root_applied']
    assert p['catalogue_count'] == 18 and p['rejected_count'] == 0 and p['not_ready'] == []
    assert p['manager']['node_enrollment'] == 'complete'
    assert p['principal']['status'] == 'available'
    assert p['principal']['pointer'] == 'stored'
    assert p['principal']['self_hosting'] == 'committed'

document['passed'] = True
record.write_text(json.dumps(document, indent=2) + '\n')
