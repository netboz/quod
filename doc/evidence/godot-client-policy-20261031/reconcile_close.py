"""Offline interpretation of the retained close observations; never launch a client."""
import json
from pathlib import Path
from hashes import TASK, raw
ev=Path(__file__).resolve().parent
label='shutdown-owner-observation02'
private=TASK/'private'/label
receipt=json.loads((private/'result.raw.json').read_text())
wrapper=json.loads((ev/'logs'/(label+'.json')).read_text())
assert wrapper['child_exit']==1 and not wrapper['timed_out']
assert receipt['failure']=='AssertionError: ' and not receipt['passed']
assert all(c['true_exit']==0 for c in receipt['children'].values())
assert all(receipt['eof'].values()) and not receipt['reader_errors']
assert receipt['children']['client-shutdown-owner']['explicit_completion']
assert receipt['native_input_count']==0 and not receipt['host_input_or_focus_action']
for n,r in receipt['streams'].items():
    p=Path(r['path']);assert raw(p)==r['sha256'] and p.stat().st_size==r['bytes']
stages=receipt['close_stages']
assert all(r['status']=='RanToCompletion' for r in stages if r['stage'].endswith('.settled') and r['status'] is not None)
milestones=[r for r in stages if r['status'] is None]
expected=['session.close.begin','session.close.returned','owners.await','owners.settled',
          'models.settled','xr.shutdown.begin','xr.shutdown.returned',
          'identity.release.begin','identity.release.returned','tree.quit.requested','tree.exit.entered']
assert [r['stage'] for r in milestones]==expected
assert all(a['monotonic']<=b['monotonic'] for a,b in zip(milestones,milestones[1:]))
assert len([r for r in stages if r['stage']=='models.settled'])==2
assert not receipt.get('shutdown_capture') and not receipt.get('post_completion_trigger')
rows=[json.loads(s[10:]) for s in (private/'client-shutdown-owner-stdout.raw').read_text().splitlines() if s.startswith('M1B_STATE ')]
last=rows[-1];metrics=last['controller_metrics']
assert last['scene_count']==last['live_sockets']==metrics['sources']==metrics['appearances']==metrics['captures']==0
assert not metrics['Running']
report={'original_wrapper_exit':1,'original_failure_retained':True,
        'reconciliation':'Duplicate observation names, distinguished by task-status versus awaited milestone',
        'actual_children':{n:c['true_exit'] for n,c in receipt['children'].items()},
        'actual_checks':receipt['children']['client-shutdown-owner']['checks'],
        'eof':receipt['eof'],'final_resources_zero':True,'xr_running':False,
        'milestones':milestones,'task_statuses':[{k:r[k] for k in ['stage','status']} for r in stages if r['status'] is not None],
        'source_receipt_sha256':raw(private/'result.raw.json'),
        'source_wrapper_sha256':raw(ev/'logs'/(label+'.json')),
        'shutdown_wait_recurred':False,'shutdown_cause':'unresolved','client_rerun':False,
        'close_elapsed_seconds':(milestones[-1]['monotonic']-milestones[0]['monotonic'])/milestones[0]['frequency']}
(ev/'shutdown-observation-reconciliation.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:report[k] for k in ['actual_children','actual_checks','close_elapsed_seconds','shutdown_cause','client_rerun']}))
