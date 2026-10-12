from pathlib import Path
import json,signed as s,install_core02 as c
p=Path(__file__).resolve().parent
assert json.loads((p/'gallery-authored-installed.json').read_text())['inactive']
ns='<<"acceptance:physics:259:04:gallery">>';a=json.loads((p/'gallery-anchor-text-trimmed.json').read_text());me=c.refs['human']
q=ns+'::(current_ontology_identity('+ns+','+a+'),transaction((physics_space(room,disabled,physics_authority),physics_structure(room,4),physics_next_body(room,3),current_principal('+me+'),assertz(hinged_example_owner(room,'+me+')),assertz(hinged_example_permission(room,3,'+me+')),Rx is -400,physics_add_hinged(room,3,4,local(container_lid,1),pose(vector(0,1200,0),rotation(Rx,0,0)),4),physics_body_capacity(room,1),physics_reserve_body_ids(room,[5]),physics_advance_structure(room,Next),physics_checked_body(5,fixed,vector(0,1300,1200),box(200,1000,200),1,1000000),assertz(physics_body_definition(room,5,Next,fixed,vector(0,1300,1200),owned(box(200,1000,200),1))),retract(physics_space(room,disabled,physics_authority)),assertz(physics_space(room,enabled,physics_authority))))).'
(p/'gallery-provision.goal.prolog').write_text(q+'\n')
r=s.run('gallery-provision','execute',q);assert r.get('result')=='ok',r
print({k:r.get(k) for k in ['result','operation_id','tx_id']})
v=s.run('gallery-provision-scene','read',ns+'::world_view(room,playing,Marks).');assert v.get('result')=='ok',v
