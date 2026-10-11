from pathlib import Path
import base64,json,subprocess,time
p=Path(__file__).resolve().parent
scope=json.loads((p/'execution/scope.json').read_text())
out=p/'diagnosis-01';out.mkdir()
for i,node in enumerate(scope['allocations']):
 expression='Ns = <<"acceptance:physics:258:gallery">>, Source = <<"acceptance:physics:258:objects">>, {ok,Ref} = quod_node_actor:reference(), {ok,Key} = application:get_env(quod,node_pubkey), #{world_state => iolist_to_binary(io_lib:format("~0p",[quod_ontology:local_state(Ns)])), source_state => iolist_to_binary(io_lib:format("~0p",[quod_ontology:local_state(Source)])), world_genesis => iolist_to_binary(io_lib:format("~0p",[quod_ontology:genesis_anchor(Ns)])), root_applied => quod_prolog:applied(<<"quod:root">>), node_create_policy => iolist_to_binary(io_lib:format("~0p",[quod_prolog:prove_ro(<<"quod:root">>,{can_create_ontology,{node,Key},Ns,[]})])), agent_create_policy => iolist_to_binary(io_lib:format("~0p",[quod_prolog:prove_ro(<<"quod:root">>,{can_create_ontology,Ref,Ns,[]})]))}'
 command=['nomad','alloc','exec','-i=false','-t=false','-address=http://192.168.1.10:4646','-task','quod',node['allocation'],'/opt/quod/bin/quod','eval','binary_to_list(base64:encode(iolist_to_binary(json:encode(begin '+expression+' end)))).']
 (out/(str(i)+'.intent.json')).write_text(json.dumps({'command':command},indent=2)+'\n')
 result=subprocess.run(command,capture_output=True,text=True)
 (out/(str(i)+'.stdout')).write_text(result.stdout)
 (out/(str(i)+'.stderr')).write_text(result.stderr)
 (out/(str(i)+'.exit.json')).write_text(json.dumps({'child_exit':result.returncode})+'\n')
 assert result.returncode == 0
 wire=json.loads(result.stdout)
 if isinstance(wire,list):wire=bytes(wire).decode()
 answer=json.loads(base64.b64decode(wire))
 (out/(str(i)+'.json')).write_text(json.dumps(answer,indent=2)+'\n')
 print(i,answer)
