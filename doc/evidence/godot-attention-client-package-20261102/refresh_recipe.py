"""Advance only the offline recipe's evidence binding after causal journey02."""
import json,os,shutil
from pathlib import Path
from hashes import TASK,raw,Digests
os.umask(0o077);ev=Path(__file__).resolve().parent;root=Path.cwd()
ref=json.loads((ev/'inputs/launch-recipe.json').read_text());assert raw(ref['prepared'])==ref['sha256']
old=json.loads(Path(ref['prepared']).read_text());d=Digests()
cache=old['digest_cache'];assert raw(cache['path'])==cache['sha256']
for r in json.loads(Path(cache['path']).read_text())['records']:d.values[tuple(r['stat_key'])]=r['sha256']
current=json.loads((ev/'inputs/attention-package-journey02.json').read_text())
assert current['passed'] and all(c['true_exit']==0 for c in current['children'].values()) and all(current['eof'].values())
server=json.loads((ev/'inputs/server-attention-package-journey02-server.json').read_text())
assert {n:r['sha256'] for n,r in server['executed_current_sources'].items()}=={n:r['sha256'] for n,r in old['qualified_server']['executed_sources'].items()}
old.update(current_combined_journey_reopen_qualified=True,
  reason='Current signed software journey/reopen qualified. A fresh current-source native readiness observation and user start remain required; historical269 bootstrap is not this product.',
  qualified_server={'stage':server['stage'],'executed_sources':server['executed_current_sources']},
  prior_recipe=ref,current_journey={'path':str(ev/'inputs/attention-package-journey02.json'),'sha256':d.h(ev/'inputs/attention-package-journey02.json')},
  argv_and_environment_unchanged=True)
old['source_bindings'][str(Path(__file__).resolve().relative_to(root))]=d.h(Path(__file__))
out=TASK/'private/attention-package-offline-recipe02';out.mkdir(mode=0o700,exist_ok=False)
cache_path=TASK/'cache/attention-package-offline-recipe02-hashes.json';d.write(cache_path);old['digest_cache']={'path':str(cache_path),'sha256':raw(cache_path)}
target=out/'prepared.json';target.write_text(json.dumps(old,indent=2)+'\n')
shutil.copy2(ev/'inputs/launch-recipe.json',ev/'inputs/launch-recipe-before02.json')
(ev/'inputs/launch-recipe.json').write_text(json.dumps({'passed':True,'prepared':str(target),'sha256':raw(target),'nothing_launched':True,'human_launch_ready':False},indent=2)+'\n')
print(json.dumps({'nothing_launched':True,'current_software_journey':True,'native_readiness_unverified':True,'prepared':str(target)}))
