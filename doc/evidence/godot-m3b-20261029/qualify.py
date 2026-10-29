#!/usr/bin/env python3
"""Bind final bounded acceptance to completed children and unchanged inputs."""
import hashlib
import json
from pathlib import Path
import re
import subprocess

root=Path.cwd();evidence=Path(__file__).resolve().parent
def read(name):return json.loads((evidence/name).read_text())
def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
gates=read('gates01-result.json');assert gates['all_true_exits_zero'] and gates['source_unchanged']
assert len(gates['results'])==6 and not gates['unrun'] and not gates['explicitly_stopped']
assert all(row['child_exit']==0 and row['completion_confirmed'] and not row['timed_out'] for row in gates['results'])
client=read('inputs/client-final03-manifest.json');assert client['passed'] and client['authored_inputs_unchanged']
server=read('inputs/gates01-source-manifest.json');compiled=read('inputs/gates01-compiled-manifest.json')
for mapping,stage in [(client['authored_inputs'],Path(client['source'])),(server['files'],Path(server['stage'])/'source')]:
    for name,expected in mapping.items():assert digest(root/name)==expected and digest(stage/name)==expected,name
for name,row in client['export_outputs'].items():assert digest(Path(client['source'])/name)==row['sha256'],name
assert 'CORE_PASS checks=183' in (evidence/'client-final03-core/output.log').read_text()
assert len(client['authored_inputs'])==63 and len(client['export_outputs'])==195
physics=read('physics-final03/campaign.json');physical=read('physics-final03/client-result.json')
assert physics['passed'] and physics['client_child_exit']==physics['server_child_exit']==0 and physical['passed']
assert 'M3_PHYSICS_PASS' in (evidence/'physics-final03/client.log').read_text()
serial=read('serial-final03-result.json');assert serial['passed'] and len(serial['results'])==3
campaigns={}
for journey in ['navigation','gui','spaces']:
    label='final-'+journey+'-final03';campaign=read(label+'-campaign.json')
    assert campaign['passed'] and campaign['server_child_exit']==0
    assert all(command['child_exit']==0 for command in campaign['commands'])
    factory=read('inputs/server-'+label+'-server.json')
    assert factory['profile']=='prod' and not factory['runtime_recompiled'] and factory['child_exit']==0
    for name,row in factory['driver_sources'].items():assert digest(Path(row['path']))==row['sha256'],name
    campaigns[journey]=dict(label=label,passed=True,actual_commands=campaign['commands'],profile='prod')
head=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
assert head=='f716ddf5e578df957a5b18421a0727a32c634f87'
counts={}
for gate,pattern in [('native',r'test result: ok\. (\d+) passed'),('eunit',r'All (\d+) tests passed'),('ct',r'All (\d+) tests passed')]:
    counts[gate]=int(re.search(pattern,(evidence/'logs'/('gates01-'+gate+'.log')).read_text())[1])
counts.update(xref=True,dialyzer=True,local_release=True)
scope=read('inputs/source-scope-final.json')
receipt=dict(schema='quod-m3b-bounded-desktop-v1',head=head,branch='worktree/pearl-stone',
    parent='69196a36caeeb06e6ee07982f1ab1988d7c16b43',original_branch_base='f6c29fe925e666dd68ee7fa68c0e03f5d03391a2',
    worker_session='8b352c53-1f93-4e4c-8d1f-c5f41e8efbb8',coordinator='ed9cd520-b2a4-4607-a8f5-ff99d08f3e46',
    api_model='openai-codex:gpt-6.1-sol',requested_effort='max',effective_effort='Not exposed by installed API',
    clean_sequential_gates=counts,true_child_exits=[r['child_exit'] for r in gates['results']],
    server_inputs=len(server['files']),compiled_counts=compiled['counts'],client_inputs=63,client_core_checks=183,
    client_export_entries=195,physical_checks=len(physical['checks']),physical_stream_frames=physical['frames'],
    final_physics_profile='prod',final_campaigns=campaigns,source_scope=scope['totals'],production_relocations=0,
    authored_inputs_unchanged=True,compiled_application_inputs_copied=False,shared_publication=False,committed=False,
    bounded_desktop_outcome_verified=True,full_m3_complete=False,coordinator_verification_pending=True,
    negative_boundary='Retained association without target claim remains nonterminal. Fresh process/device retains the unknown barrier and submits no replacement instruction.',
    tracker_metadata=dict(quo64_status='in-review',quo64_progress=13,parent_progress=50,stage2_progress=25),
    remaining=['Coordinator verification and commit authority','Portable terminal rejection is not established for the no-target-claim case',
        'Framed terrain and broad independent-run migration','Broader ontology editing and unfinished D5/D6/D7',
        'Controller/Vive/XR hardware, power-cut and non-Linux acceptance'],
    immutable_snapshot='/home/yan/.cache/quod-m3b-artifacts/quod-godot-m3b-handoff-8b352c53-20261029-02')
output=evidence/'qualification.json';assert not output.exists();output.write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps({k:receipt[k] for k in ['clean_sequential_gates','client_core_checks','client_export_entries','physical_checks','bounded_desktop_outcome_verified','full_m3_complete']}))
