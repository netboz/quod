from pathlib import Path
import json,sys,subprocess
import install_core02 as c,owner,signed as s
p=Path(__file__).resolve().parent
try:
 assert json.loads((p/'core02-installed.json').read_text())['predicates']==55
 base=owner.inactive('personal-authored-before',c.ns)
 for n,row in enumerate(json.loads((p/'personal-replacements.json').read_text()),1):
  op=c.install('personal-authored-'+str(n).zfill(2),row['indicator'],row['expected'],row['draft'])
  a=owner.inactive('personal-authored-'+str(n).zfill(2),c.ns);assert a['anchor']==base['anchor'] and a['bodies']==base['bodies']
  print(json.dumps({'index':n,'indicator':row['indicator'],'operation_id':op,'height':a['height']}),flush=True)
 (p/'personal-authored-installed.json').write_text(json.dumps({'predicates':10,'inactive':True,'original_bodies_unchanged':True})+'\n')
except BaseException as e:
 (p/'personal-authored-STOP.json').write_text(json.dumps({'type':type(e).__name__,'reason':str(e),'rule':'Resolve original operation; never rerun'})+'\n');raise
