from pathlib import Path
import json
import install_core02 as c,owner,signed as s
p=Path(__file__).resolve().parent
assert json.loads((p/'gallery-core04-installed.json').read_text())['predicates']==55
c.ns='acceptance:physics:259:04:gallery';c.world='room';c.refs=c.refs|{'namespace':'<<"'+c.ns+'">>','anchor':json.loads((p/'gallery-anchor-text-trimmed.json').read_text())}
try:
 base=owner.inactive('gallery-authored-before',c.ns)
 for n,row in enumerate(json.loads((p/'gallery-replacements.json').read_text()),1):
  op=c.install('gallery-authored-'+str(n).zfill(2),row['indicator'],row['expected'],row['draft'])
  a=owner.inactive('gallery-authored-'+str(n).zfill(2),c.ns);assert a['anchor']==base['anchor'] and a['bodies']==base['bodies']
  print(json.dumps({'index':n,'indicator':row['indicator'],'operation_id':op,'height':a['height']}),flush=True)
 (p/'gallery-authored-installed.json').write_text(json.dumps({'predicates':16,'inactive':True,'original_bodies_unchanged':True})+'\n')
except BaseException as e:
 (p/'gallery-authored-STOP.json').write_text(json.dumps({'type':type(e).__name__,'reason':str(e),'rule':'Resolve original operation; never rerun'})+'\n');raise
