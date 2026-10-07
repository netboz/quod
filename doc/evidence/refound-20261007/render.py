from pathlib import Path
repo = Path('/home/yan/src/quod')
out = Path('/tmp/quod-candidate-refound-252-20261007-v2')
job = 'quod-finality-candidate-v6-20260926'
family = job + '-refound-20261007-v2'
text = (repo / 'deploy/quod.nomad').read_text()
repls = [
    ('job "quod" {', f'job "{job}" {{', 1),
    ('source    = "quod-node-local"', f'source    = "{family}"', 1),
    ('source    = "quod-node-cloud"', f'source    = "{family}-cloud"', 1),
    ('range service "quod-metrics|any"', f'range service "{job}-quod-metrics|any"', 2),
    ('range service "quod"', f'range service "{job}-quod"', 2),
    ('        name = "quod"', f'        name = "{job}-quod"', 2),
    ('        name = "quod-metrics"', f'        name = "{job}-quod-metrics"', 2),
    ('        name = "explorer"', f'        name = "{job}-explorer"', 2),
    ('        name = "client"', f'        name = "{job}-client"', 2),
    ('        tags = ["quod", "client", "web"]', '        tags = ["quod", "client", "web", "candidate-quod-node-${NOMAD_ALLOC_INDEX}"]', 1),
    ('        tags = ["quod", "client", "web", "cloud"]', '        tags = ["quod", "client", "web", "cloud", "candidate-quod-cloud-${NOMAD_ALLOC_INDEX}"]', 1),
    ('service.namespace=quod,deployment.environment=nomad', f'service.namespace={job},deployment.environment=nomad', 2),
]
for old, new, expected in repls:
    actual = text.count(old)
    assert actual == expected, (old, actual, expected)
    text = text.replace(old, new)
assert 'source    = "quod-node-local"' not in text
assert 'range service "quod"' not in text
assert f'job "{job}"' in text
(out / 'candidate-refound.nomad').write_text(text)
source = (repo / 'deploy/volumes/quod-node-local.hcl').read_text()
nodes = [
    '3e390ebd-5557-a67c-b64e-07b728144297',
    '75b1a578-a5f6-e5b9-70cb-9e3aca6baac0',
    'c8f9edef-853b-fc43-e3fb-d884418f7061',
]
for i in range(8):
    volume = source.replace('quod-node-local[0]', f'{family}[{i}]').replace('__COMPUTE_NODE_ID__', nodes[i % len(nodes)])
    assert '__COMPUTE_NODE_ID__' not in volume
    (out / 'volumes' / f'{i}.hcl').write_text(volume)
(out / 'scope.txt').write_text(f'job={job}\nvolume_family={family}\nimage=192.168.1.11:5000/quod:0.7.252@sha256:2d7ed2e31d9b38eb88501501b8b7b39a2dc189a5438013d05ba97524839b441d\n')
