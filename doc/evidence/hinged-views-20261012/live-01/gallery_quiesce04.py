from pathlib import Path
import json,owner,base64
p=Path(__file__).resolve().parent
ns='acceptance:physics:259:04:gallery';anchor='41EF1E056943B629AC1DCA71B13BA0028ABDE7FB7B0F91756604334A2F07B69B'
expression='''Ns= <<"acceptance:physics:259:04:gallery">>,A=binary:decode_hex(<<"41EF1E056943B629AC1DCA71B13BA0028ABDE7FB7B0F91756604334A2F07B69B">>),Me={agent_instance_ref,<<"human:5pU3X8evhfH09g1ctl0LRRP80zmhd6M7g8OQ7DyOeaE">>,binary:decode_hex(<<"758F8AA13D54CF626BA493A6BFBEC24548AC96B49DD0FEDA3BC0843E0838CBF2">>),me},
{ok,P}=quod_node_actor:reference(),{ok,[_],_}=quod_prolog:prove_ro(Ns,{acceptance_actor,P}),
Goals=[{physics_run,room,{'G'},{'_'}},{physics_custody,room,{'C'}},{physics_previous_complete,{'C'},{'G'}},{list_to_atom([92,43]),{acceptance_actor,Me}},{assertz,{acceptance_actor,Me}},{retract,{physics_space,room,enabled,physics_authority}},{assertz,{physics_space,room,disabled,physics_authority}}],
[First|Rest]=lists:reverse(Goals),Body=lists:foldl(fun(X,Acc)->{',',X,Acc} end,First,Rest),
Goal={'::',Ns,{',',{current_ontology_identity,Ns,A},{transaction,Body}}},
{Canonical,_,_}=erlog_int:term_instance(Goal,0),
{ok,B,S}=quod_node_actor:signed_goal(execute,Canonical,crypto:strong_rand_bytes(32),quod_time:now_ms()+30000),
#{bytes=>base64:encode(B),signature=>base64:encode(S),existing_owner_authorized=>true}'''
r=owner.read('gallery-quiesce04-prepare',expression)
q='R=quod_client_goal_ingress:submit(base64:decode(<<"'+r['bytes']+'">>),base64:decode(<<"'+r['signature']+'">>)),#{result=>iolist_to_binary(io_lib:format("~0p",[R]))}'
a=owner.read('gallery-quiesce04-submit',q,read_only=False);assert a['result'].startswith('{ok,'),a
owner.inactive('gallery-inactive-before04',ns)
print('gallery quiesced by existing authenticated owner; retained me granted instance source authority')
