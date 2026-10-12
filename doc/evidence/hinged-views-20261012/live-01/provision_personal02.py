from pathlib import Path
import json,sys
import signed as s,install_core02 as c
p=Path(__file__).resolve().parent;r=c.refs
assert json.loads((p/'personal-authored-installed.json').read_text())['inactive']
base=s.run('personal-base-scene-before-add02','read',r['namespace']+'::lobby_view(playing,Marks).');assert base.get('result')=='ok',base
q=r['namespace']+'::(current_ontology_identity('+r['namespace']+','+r['anchor']+'),transaction((physics_space(personal_lobby,disabled,physics_authority),physics_structure(personal_lobby,1),physics_next_body(personal_lobby,5),current_principal('+r['human']+'),assertz(hinged_example_owner(personal_lobby,'+r['human']+')),assertz(hinged_example_permission(personal_lobby,5,'+r['human']+')),X is -5000,physics_add_hinged(personal_lobby,5,6,local(vertical_door,1),vector(X,1200,1400),1),OX is -3500,physics_body_capacity(personal_lobby,1),physics_reserve_body_ids(personal_lobby,[7]),physics_advance_structure(personal_lobby,Next),physics_checked_body(7,fixed,vector(OX,1200,900),box(200,1000,200),1,1000000),assertz(physics_body_definition(personal_lobby,7,Next,fixed,vector(OX,1200,900),owned(box(200,1000,200),1))),retract(physics_space(personal_lobby,disabled,physics_authority)),assertz(physics_space(personal_lobby,enabled,physics_authority))))).'
(p/'personal-provision.goal.prolog').write_text(q+'\n')
a=s.run('personal-provision','execute',q);print(json.dumps(a));assert a.get('result')=='ok',a
view=s.run('personal-scene-after-add','read',r['namespace']+'::world_view(personal_lobby,playing,Marks).');assert view.get('result')=='ok',view
print('provision committed; authored scene readback retained')
