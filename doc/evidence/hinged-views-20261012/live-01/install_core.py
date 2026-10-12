from pathlib import Path
import datetime,json,sys
import browser as b,signed as s,owner
p=Path(__file__).resolve().parent
refs=json.loads((p.parents[2]/'quod27-personal-259-01/references.json').read_text())
rows=json.loads((p.parent/'source-preparation/replacement-drafts-02.json').read_text())
ns='human:5pU3X8evhfH09g1ctl0LRRP80zmhd6M7g8OQ7DyOeaE/lobby';world='personal_lobby'
def binary(value):return '<<"'+value.replace('\\','\\\\').replace('"','\\"').replace('\n','\\n').replace('\r','\\r').replace('\t','\\t')+'">>'
def install(label,indicator,expected,draft):
 target='ontology_ref('+refs['namespace']+','+refs['anchor']+')';prefix='<<"quod:prolog">>::(current_ontology_identity(<<"quod:prolog">>,'+refs['editor']+'),'
 q=prefix+'prolog_edit_goal('+target+','+indicator+','+binary(expected)+','+binary(draft)+',Edit)).'
 c=s.run(label+'-compile','read',q);assert c.get('result')=='ok',(label,c)
 g=s.run(label+'-guard','guard',c['bindings'][0]['Edit'],world)
 proof=s.run(label+'-proof','cursor',g);assert proof.get('result')=='solution',(label,proof)
 r=s.run(label+'-accept','command',proof['cursor'],'accept');assert r.get('result')=='ok',(label,r)
 a=s.run(label+'-readback','read',prefix+'prolog_source('+target+','+indicator+',Source)).');assert a.get('result')=='ok',(label,a)
 value=s.run(label+'-canonical','source',a['bindings'][0]['Source']);assert value==draft,(label,'source mismatch')
 return proof['operation_id']
def main():
 script="""const done=arguments[0];import('/explorer/assets/world-CblDwDXV.js').then(m=>{const c=m.v,a=m.g;const shape=(t,f,k)=>t?.type==='compound'&&t.functor===f&&t.args.length===k;quod27Evidence.source=b=>new TextDecoder('utf-8',{fatal:true}).decode(m.h(b).value);quod27Evidence.guard=(binding,world)=>{const e=m.h(binding),pair=e.args[1],tx=pair.args[1];if(!shape(e,'::',2)||!shape(pair,',',2)||!shape(tx,'transaction',1))throw Error('unexpected compiler edit');return m.y(c('::',[e.args[0],c(',',[pair.args[0],c('transaction',[c(',',[c('physics_space',[a(world),a('disabled'),a('physics_authority')]),tx.args[0]])])])]))};done(true)})"""
 assert b.command('/execute/async',{'script':script,'args':[]}) is True
 baseline=owner.inactive('personal-inactive-before',ns)
 for n,row in enumerate(rows,1):
  label='core-'+str(n).zfill(3)
  if n%20==0:assert s.run(label+'-renew','renew').get('renewed')
  op=install(label,row['indicator'],row['expected'],row['draft'])
  observed=owner.inactive(label,ns);assert observed['anchor']==baseline['anchor'] and observed['bodies']==baseline['bodies']
  print(json.dumps({'index':n,'total':len(rows),'indicator':row['indicator'],'operation_id':op,'height':observed['height'],'inactive':True}),flush=True)
 with (p/'core-installed.json').open('x') as f:json.dump({'predicates':len(rows),'inactive':True,'original_bodies_unchanged':True},f)
if __name__=='__main__':
 try:main()
 except BaseException as e:
  with (p/'core-install-STOP.json').open('x') as f:json.dump({'type':type(e).__name__,'reason':str(e),'rule':'Resolve original operation, never rerun driver'},f)
  raise
