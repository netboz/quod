"""Recognize exact artifacts published by the existing fixture source owner."""
import json
from pathlib import Path
def server_artifacts(root,h):
    ev=root/'doc/evidence/godot-m4-vive-physical-20261029';result=set()
    for number in ['10']:
        label='native-vive-product'+number+'-server'
        receipt=ev/'inputs'/('server-'+label+'.json')
        row=json.loads(receipt.read_text())
        assert row['profile']=='prod' and not row['runtime_recompiled']
        assert row['stage'].endswith('/server-runtime-restoration'+'05')
        assert set(row['driver_sources'])=={'serve.py','godot_m3b_fixture.erl','godot_m3b_physics_fixture.erl'}
        result.add(str(receipt.relative_to(root)))
        for name,entry in row['driver_sources'].items():
            actual=Path(entry['path']);assert actual==ev/'inputs'/(label+'-'+name)
            assert h(actual)==entry['sha256']==h(ev/name)
            result.add(str(actual.relative_to(root)))
    assert len(result)==4
    return result
