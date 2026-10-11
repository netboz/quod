from pathlib import Path
import json, subprocess, sys, time, uuid

out = Path(__file__).resolve().parent
image, label = sys.argv[1:]
evidence = out / label
evidence.mkdir()
rendered = subprocess.check_output([
    'nomad', 'job', 'run', '-output', '-var=bootstrap=true',
    '-var=cloud_node_count=0', str(out.parent/'gates-03/tree/deploy/quod.nomad')])
job = json.loads(rendered)['Job']
group = next(g for g in job['TaskGroups'] if g['Name'] == 'quod-node')
tasks = {t['Name']: t for t in group['Tasks']}
config = next(t['EmbeddedTmpl'] for t in tasks['quod']['Templates']
              if t['DestPath'].endswith('quod.conf'))
config = config.replace('{{ env "attr.unique.network.ip-address" }}', '127.0.0.1')
config = config.replace('{{ env "NOMAD_HOST_PORT_p2p" }}', '14567')
assert '{{' not in config and '${' not in config
(evidence/'quod.conf').write_text(config)
script = tasks['prepare-agent-vault']['Config']['args'][0]
script += '\nexec /opt/quod/bin/quod foreground\n'
volume='quod-vault-boot-'+uuid.uuid4().hex
subprocess.run(['docker','volume','create','--label','org.quod.purpose=local-vault-boot-check',volume],check=True,stdout=subprocess.DEVNULL)
try:
    command = ['docker', 'run', '--rm', '--network=none', '--memory=768m',
               '--entrypoint=/bin/sh',
               '--mount', 'type=volume,source='+volume+',target=/quod/data',
               '--mount', 'type=bind,source='+str(out)+',target=/probe,readonly',
               '--mount', 'type=bind,source='+str(evidence)+',target=/evidence',
               '--env', 'QUOD_DATA_DIR=/quod/data',
               '--env', 'QUOD_CONF=/evidence/quod.conf',
               '--env', 'ERL_FLAGS=-pa /probe -s code ensure_modules_loaded quod_vault_boot_probe -s quod_vault_boot_probe run',
               image, '-c', script]
    (evidence/'intent.json').write_text(json.dumps({'image': image,
        'scope': 'network-disabled disposable local container',
        'rendered_config': 'quod.conf', 'probe': 'quod_vault_boot_probe.erl'}, indent=2)+'\n')
    start = time.monotonic()
    with (evidence/'boot.log').open('xb') as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    (evidence/'receipt.json').write_text(json.dumps({'exit': result.returncode,
        'seconds': time.monotonic()-start}, indent=2)+'\n')
    assert result.returncode == 0, 'boot failed; see retained log'
    answer = json.loads((evidence/'boot-result.json').read_text())
    assert answer['passed'] and answer['vault_ready'] and answer['root_ready']
    print(json.dumps(answer))

finally:
    subprocess.run(['docker','volume','rm',volume],check=True,stdout=subprocess.DEVNULL)
