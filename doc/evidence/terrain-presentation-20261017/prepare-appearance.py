"""Prepare ordinary source edits and an exact-default owner request; no writes online."""
from pathlib import Path
import json,re
r=Path('/home/yan/src/quod');e=r/'doc/evidence/terrain-presentation-20261017'
b=r/'_build/terrain-presentation-20261017/deployment-274-rolling'
frozen=r/'_build/terrain-presentation-20261017/review-04/tree'
def between(s,a,z):return s[s.index(a):s.index(z,s.index(a))].strip()+'\n'
def binary(s):return '<<'+json.dumps(s,ensure_ascii=False)+'>>'
old=(e/'before/priv/ontologies/quod_lobby.pl').read_text()
new=(frozen/'priv/ontologies/quod_lobby.pl').read_text()
rows=[('lobby_query/1',between(old,'lobby_query(lobby_modes','%% A user'),between(new,'lobby_query(lobby_modes','%% A user')),
      ('lobby_options/3',between(old,'lobby_options(Owner, Node, Options) :-','%% Authored floor'),between(new,'lobby_options(Owner, Node, Options) :-','%% Authored floor')),
      ('world_palette/1','',between(new,'world_palette([','%% Roof'))]
parts=['quod:root::system_ontology(<<"quod:lobby">>,A)','quod:root::system_ontology(<<"quod:prolog">>,P)']
for i,(pred,prev,nxt) in enumerate(rows):
    parts.append('<<"quod:prolog">>::(current_ontology_identity(<<"quod:prolog">>,P),prolog_edit_goal(ontology_ref(<<"quod:lobby">>,A),'+pred+','+binary(prev)+','+binary(nxt)+',E'+str(i)+'))')
parts.append('Edit = transaction((E0,E1,E2))')
(b/'shared-appearance-prepare.pl').write_text(',\n'.join(parts)+'.\n')
(b/'shared-appearance-delta.json').write_text(json.dumps([{'predicate':p,'before':x,'after':y} for p,x,y in rows],indent=2)+'\n')
o=(e/'before/priv/ontologies/lobby_worlds.pl').read_text()
n=(frozen/'priv/ontologies/lobby_worlds.pl').read_text()
creation_old=between(o,'world_creation_entered(EnteredName,Recipe) :-','world_library_count(Count) :-')
creation_new=between(n,'world_creation_entered(EnteredName,Recipe) :-','world_library_count(Count) :-')
palette_old=between(o,'world_palette([','%% Allocate')
palette_new=between(n,'world_palette(Palette) :-','space_member(W,')
oldpalette=re.search(r'world_palette\((\[[\s\S]*?\])\)\.',palette_old)[1]
sky=between(n,'        assertz(instance_of(sky_sphere,world_sky(W)))','        world_palette(Palette),').rstrip().rstrip(',')
rule=between(n,'space_member(W,','%% Allocate').rstrip().rstrip('.')
for oldvar,newvar in [('W','SkyWorld'),('Ns','SkyNamespace'),('A','SkyAnchor')]:
    rule=re.sub(r'\b'+oldvar+r'\b',newvar,rule)
prefix=['lobby_reference(ontology_ref(L,A))','quod:root::system_ontology(<<"quod:prolog">>,P)']
for i,(pred,prev,nxt) in enumerate([('world_creation_entered/2',creation_old,creation_new),('world_palette/1',palette_old,palette_new)]):
    prefix.append('<<"quod:prolog">>::(current_ontology_identity(<<"quod:prolog">>,P),prolog_edit_goal(ontology_ref(L,A),'+pred+','+binary(prev)+','+binary(nxt)+',E'+str(i)+'))')
body=r'''current_ontology_identity(L,A),current_principal(Human),lobby_owner(Human),
findall(V,(lobby_terrain_world(V),attribute(V,display_name,WORLD_NAME)),[W]),
findall(presentation(Id,Pal,V,R),voxel_presentation(W,Id,Pal,V,R),[presentation(<<"terrain">>,OLD_PALETTE,View,Resources)]),
\+ instance_of(sky_sphere,world_sky(W)),
findall(B,attribute(personal_sky,brightness,B),[120]),
\+ clause(space_member(V,entity_ref(N,A0,world_sky(V))),(lobby_terrain_world(V),current_ontology_identity(N,A0))),
assertz((SKY_RULE)),
retract(attribute(personal_sky,brightness,120)),assertz(attribute(personal_sky,brightness,1000)),
lobby_vocabulary(Vocabulary,VocabularyAnchor),
Vocabulary::(current_ontology_identity(Vocabulary,VocabularyAnchor),world_palette(Palette)),
retract(voxel_presentation(W,<<"terrain">>,OLD_PALETTE,View,Resources)),
assertz(voxel_presentation(W,<<"terrain">>,Palette,View,Resources)),
SKY_FACTS,voxel_validate_presentation(W)'''
body=body.replace('OLD_PALETTE',oldpalette).replace('SKY_RULE',rule).replace('SKY_FACTS',sky)
request='transaction((\n'+',\n'.join(prefix)+',\ncall(E0),call(E1),\nL::('+body+'))).\n'
for name,label in [('wild-realm-owner-update.pl','Wild Realm'),('acceptance-owner-update.pl','Highland Retreat')]:
    (b/name).write_text(request.replace('WORLD_NAME',binary(label)))
print(json.dumps({'shared_predicates':[p for p,_,_ in rows],'owner_goal_bytes':len(request.encode()),'submitted':False}))
