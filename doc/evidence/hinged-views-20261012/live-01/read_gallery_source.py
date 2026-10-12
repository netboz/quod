from pathlib import Path
import json
import browser as b
import signed as s
p=Path(__file__).resolve().parent
b.command('/execute/async',{'script':"const done=arguments[0];import('/explorer/assets/world-CblDwDXV.js').then(m=>{quod27Evidence.decode=binding=>{const t=m.h(binding);if(t.type==='binary')return new TextDecoder().decode(t.value);if(t.type==='compound'&&t.functor==='source_chunk')return {status:t.args[0].value,text:new TextDecoder().decode(t.args[1].value)};throw Error('bad chunk')};done(true)})",'args':[]})
q='<<"acceptance:physics:259:04:gallery">>::prolog_introspection(chunks(8192),Chunk).'
r=s.run('gallery-source-cursor','cursor',q);cursor=r.get('cursor');parts=[]
try:
 for n in range(100):
  assert r.get('result')=='solution',r
  v=s.run('gallery-source-chunk-'+str(n),'decode',r['bindings'][0]['Chunk']);parts.append(v['text'])
  print(n,v['status'],len(v['text']),flush=True)
  if v['status']=='done':break
  r=s.run('gallery-source-next-'+str(n),'command',cursor,'next');cursor=r.get('cursor',cursor)
 else:raise RuntimeError('source cursor exceeds declared bound')
finally:
 if cursor:s.run('gallery-source-stop','command',cursor,'stop')
(p/'gallery-baseline-source.prolog').write_text(''.join(parts))
