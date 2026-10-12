from pathlib import Path
import json,ast
import install_core02 as c,owner,browser as b,signed as s
p=Path(__file__).resolve().parent
assert json.loads((p/'gallery-core03-conflicts.json').read_text())==[]
c.ns='acceptance:physics:259:04:gallery';c.world='room';c.refs=c.refs|{'namespace':'<<"'+c.ns+'">>','anchor':json.loads((p/'gallery-anchor-text-trimmed.json').read_text())}
script=next(ast.literal_eval(x.value) for f in ast.parse((p/'install_core02.py').read_text()).body if isinstance(f,ast.FunctionDef) and f.name=='main' for x in f.body if isinstance(x,ast.Assign) and x.targets[0].id=='script')
assert b.command('/execute/async',{'script':script,'args':[]}) is True
try:
 assert s.run('gallery-core03-renew','renew').get('renewed')
 base=owner.inactive('gallery-core03-before',c.ns)
 for n,row in enumerate(c.rows,1):
  if n%20==0:assert s.run('gallery-core03-'+str(n)+'-renew','renew').get('renewed')
  op=c.install('gallery-core03-'+str(n).zfill(3),row['indicator'],row['expected'],row['draft'])
  a=owner.inactive('gallery-core03-'+str(n).zfill(3),c.ns);assert a['anchor']==base['anchor'] and a['bodies']==base['bodies']
  print(json.dumps({'index':n,'total':len(c.rows),'indicator':row['indicator'],'operation_id':op,'height':a['height']}),flush=True)
 (p/'gallery-core03-installed.json').write_text(json.dumps({'predicates':55,'inactive':True,'original_bodies_unchanged':True})+'\n')
except BaseException as e:
 (p/'gallery-core03-STOP.json').write_text(json.dumps({'type':type(e).__name__,'reason':str(e),'rule':'Resolve original operation; never rerun'})+'\n');raise
