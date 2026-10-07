#!/usr/bin/env python3
from pathlib import Path
import base64, json, subprocess

out = Path('/tmp/quod-candidate-refound-252-20261007-v2')
address = 'http://192.168.1.10:4646'
allocs = json.loads(subprocess.run(
    ['nomad','job','allocs','-address='+address,'-json','quod-finality-candidate-v6-20260926'],
    capture_output=True,text=True,check=True).stdout)
alloc = next(a for a in allocs if a['ClientStatus']=='running' and
             a['Name'].endswith('quod-node[0]'))
anchor = json.loads((out/'anchors.json').read_text())['modelling']
expression = f'''
Ns = <<"quod:modelling">>, Anchor = binary:decode_hex(<<"{anchor}">>),
Target={{ontology_ref,Ns,Anchor}},
{{ok,[#{{'Access' := Access}}],_}}=quod_prolog:prove_ro(
  <<"quod:root">>,{{system_source_access,Target,{{'Access'}}}}),
{{ok,[#{{'Choices' := Choices}}],_}}=quod_prolog:prove_ro(
  Ns,{{ontology_eidolons,{{'Choices'}}}}),
HasSourceEidolon=lists:any(fun({{eidolon,prolog,source,_}})->true;(_)->false end,Choices),
{{ok,[#{{'Indicators' := Indicators}}],_}}=quod_prolog:prove_ro(
  <<"quod:prolog">>,{{prolog_predicates,Target,{{'Indicators'}}}}),
{{ok,[#{{'Source' := Source}}],_}}=quod_prolog:prove_ro(
  <<"quod:prolog">>,{{prolog_source,Target,{{'/',model,2}},{{'Source'}}}}),
#{{access => Access,source_eidolon => HasSourceEidolon,
   model_predicate => lists:member({{'/',model,2}},Indicators),
   admitted_node_private_acl_visible => lists:member({{'/',can_invoke,4}},Indicators),
   source_bytes => byte_size(Source)}}
'''.strip()
encoded='binary_to_list(base64:encode(iolist_to_binary(json:encode(begin '+expression+' end)))).'
command=['nomad','alloc','exec','-i=false','-t=false','-address='+address,'-task','quod',
         alloc['ID'],'/opt/quod/bin/quod','eval',encoded]
(out/'source-probe-03.intent.json').write_text(json.dumps({'allocation':alloc['ID'],'command_argv':command},indent=2)+'\n')
result=subprocess.run(command,capture_output=True,text=True)
(out/'source-probe-03.stdout').write_text(result.stdout)
(out/'source-probe-03.stderr').write_text(result.stderr)
(out/'source-probe-03.exit.json').write_text(json.dumps({'exit':result.returncode},indent=2)+'\n')
result.check_returncode()
wire=json.loads(result.stdout)
if isinstance(wire,list): wire=bytes(wire).decode('ascii')
value=json.loads(base64.b64decode(wire,validate=True))
(out/'source-probe-03.json').write_text(json.dumps(value,indent=2)+'\n')
print(json.dumps(value,indent=2))
assert value['access']=='read_only'
assert value['source_eidolon'] and value['model_predicate']
assert value['admitted_node_private_acl_visible']
assert value['source_bytes'] > 0
