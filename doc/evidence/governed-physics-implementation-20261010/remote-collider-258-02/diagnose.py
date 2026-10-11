from pathlib import Path
import base64,json,subprocess
p=Path(__file__).resolve().parent
out=p/'diagnosis-01';out.mkdir()
scope=json.loads((p/'execution/scope.json').read_text())
editor=json.loads((p/'execution/source-editor.json').read_text())['reference']
expression='Ns=<<"acceptance:physics:258:gallery">>,{ok,Host}=quod_node_actor:reference(),{ok,Key}=application:get_env(quod,node_pubkey),Editor=binary_to_term(base64:decode(<<"EDITOR">>),[safe]),Terms=[{can_invoke,{\'_\'},Host,{\'_\'},Ns},{can_invoke,{\'_\'},Editor,{\'_\'},Ns},{can_prepare_agent_key,Host,physics_authority,none,0,Host},{can_assign_agent_host,Host,physics_authority,none,0,Host,{\'_\'}}],Options=quod_remote_collider_evidence:found_options(["agent_instance.pl","space.pl","quod_physics.pl"],Terms),{ok,[_],_}=quod_prolog:prove_ro(<<"quod:root">>,{can_create_ontology,{node,Key},Ns,Options}),{ok,Structural}=quod_ontology:validate_action({create_ontology,Ns,Options}),{ok,Prepared}=quod_ontology:prepare_action(Structural,{node,Key}),Anchor=quod_ontology:prepared_anchor(Prepared),Action={create_ontology,Ns,Options,Anchor},Encode=fun({ok,B}) when is_binary(B)->#{ok_bytes=>byte_size(B)};(E)->#{error=>iolist_to_binary(io_lib:format("~0p",[E]))} end,Config=element(5,Prepared),#{state=>iolist_to_binary(io_lib:format("~0p",[quod_ontology:local_state(Ns)])),root_applied=>quod_prolog:applied(<<"quod:root">>),action_encoding=>Encode(quod_durable_term:encode_goal(Action)),prepared_encoding=>Encode(quod_ontology:prepared_bytes(Prepared)),raw_prepared_bytes=>erlang:external_size(Prepared),config_field_sizes=>maps:from_list([{K,erlang:external_size(V)}||{K,V}<-maps:to_list(Config)]),effect_result=>iolist_to_binary(io_lib:format("~0p",[quod_ontology:prepared_effect(Action,Prepared,Key,{node,Key})]))}'.replace('EDITOR',editor).replace('Ns=<<','Ns = <<')
command=['nomad','alloc','exec','-i=false','-t=false','-address=http://192.168.1.10:4646','-task','quod',scope['allocations'][0]['allocation'],'/opt/quod/bin/quod','eval','binary_to_list(base64:encode(iolist_to_binary(json:encode(begin '+expression+' end)))).']
(out/'intent.json').write_text(json.dumps({'command':command,'scope':'Read-only authorized structural preparation diagnosis; no stage, journal, commit, or execution of prepared effect'},indent=2)+'\n')
r=subprocess.run(command,capture_output=True,text=True)
(out/'stdout').write_text(r.stdout);(out/'stderr').write_text(r.stderr)
(out/'exit.json').write_text(json.dumps({'child_exit':r.returncode})+'\n')
assert r.returncode==0
wire=json.loads(r.stdout)
if isinstance(wire,list):wire=bytes(wire).decode()
answer=json.loads(base64.b64decode(wire));(out/'result.json').write_text(json.dumps(answer,indent=2)+'\n');print(json.dumps(answer,indent=2))
