#!/usr/bin/env python3
from pathlib import Path
import base64, json, subprocess, time

out = Path('/tmp/quod-release-253-20261007')
address = 'http://192.168.1.10:4646'
job = 'quod-finality-candidate-v6-20260926'

alloc_result = subprocess.run(
    ['nomad', 'job', 'allocs', '-address='+address, '-json', job],
    capture_output=True, text=True, check=True)
allocations = [a for a in json.loads(alloc_result.stdout)
               if a['ClientStatus'] == 'running' and a['DesiredStatus'] == 'run'
               and a['TaskGroup'] == 'quod-node']
assert len(allocations) == 8, len(allocations)

expression = '''
{ok,Height,Descriptors,Rejected}=quod_system_ontology:catalog(),
NotReady=[{Ns,State} || #{namespace := Ns} <- Descriptors,
                         {ok,State} <- [quod_ontology:local_state(Ns)], State =/= ready],
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
RootStats=quod_simplex:stats(<<"quod:root">>),
#{version => list_to_binary(element(2,application:get_key(quod,vsn))),root_anchor => binary:encode_hex(quod_simplex:genesis_hash(<<"quod:root">>)),
  root_state => case quod_ontology:local_state(<<"quod:root">>) of {ok,S}->S; Other->iolist_to_binary(io_lib:format("~0p",[Other])) end,
  root_committee_size => length(quod_simplex:committee(<<"quod:root">>)),
  root_committed => maps:get(committed,RootStats),
  root_applied => maps:get(last_applied,RootStats),
  catalogue_height => Height,catalogue_count => length(Descriptors),
  rejected_count => map_size(Rejected),not_ready => NotReady,
  manager => quod_namespace_manager:stats(),principal => Principal}
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

document = {'job': job, 'job_version': 51, 'allocations': results,
            'seconds': time.monotonic() - started}
(out / 'fleet-probe.json').write_text(json.dumps(document, indent=2) + '\n')
assert all(r['exit'] == 0 for r in results)
for row in results:
    p = row['probe']
    assert p['root_anchor'] == 'C9A6B83F8F91505F23EBACF1BF0DF92692AA890AA1060E6D5F5356D642DDA34E'
    assert p['root_state'] == 'ready'
    assert p['catalogue_count'] == 18 and p['rejected_count'] == 0 and p['not_ready'] == []
    assert p['manager']['node_enrollment'] == 'complete'
    assert p['principal']['status'] == 'available'
    assert p['principal']['pointer'] == 'stored'
    assert p['principal']['self_hosting'] == 'committed'

assert all(row['probe']['version'] == '0.7.253' for row in results)
