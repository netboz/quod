from pathlib import Path
import json, statistics, math, collections, bisect, hashlib
p=Path(__file__).resolve().parent
observed=json.loads((p/'renewal-movement-01-input-animation.json').read_text())
network=json.loads((p/'renewal-movement-01-network.json').read_text())
action=json.loads((p/'renewal-movement-01-action-result.json').read_text())
child=json.loads((p/'movement-exit.json').read_text())
frames=[r for r in observed['rows'] if r['type']=='frame'];start=observed['rows'][0]['at']
offsets=[1000*(r['wallTime']-r['timestamp']) for r in network['requests']];offset=statistics.median(offsets)
relative=lambda r:r['timestamp']*1000+offset-start
stops=[];run=None
for a,b in zip(frames,frames[1:]):
    stationary=bool(a['held']) and a['held']==b['held'] and math.hypot(b['position'][0]-a['position'][0],b['position'][2]-a['position'][2])<=1e-5
    if stationary:
        if run is None:run={'start_ms':a['at']-start,'key':a['held'],'position':a['position']}
        run['end_ms']=b['at']-start;run['duration_ms']=run['end_ms']-run['start_ms']
    elif run is not None:stops.append(run);run=None
if run:stops.append(run)
times=[f['at']-start for f in frames]
projections=[]
for e in network['events']:
    if e['data']['type']!='projection':continue
    t=relative(e);frame=frames[max(0,bisect.bisect_right(times,t)-1)]
    near=[s for s in stops if s['start_ms']<=t+500 and s['end_ms']>=t-500]
    projections.append({'at_ms':t,'selection':e['data']['selection'],'held':frame['held'],'expires_ms':e['data']['expires_ms'],'longest_stationary_within_500ms':max([s['duration_ms'] for s in near],default=0),'control_sequence':e['data']['frame']['control_state']['sequence'],'registration':e['data']['frame']['registration']})
failures=[]
for r in network['responses']:
    if r.get('result')=='ok':continue
    t=relative(r);later=[relative(next_r) for next_r in network['responses'] if next_r.get('result')=='ok' and relative(next_r)>t]
    failures.append({'at_ms':t,'result':r.get('result'),'reasons':r.get('reasons'),'nearest_projection_distance_ms':min((abs(q['at_ms']-t) for q in projections),default=None),'next_ok_after_ms':min(later)-t if later else None})
physical=[e for e in network['events'] if 'frame' in e['data']]
fence_fields=['world','space','epoch','authority','generation','schema','incarnation','structure','units']
fences={json.dumps({k:e['data']['frame'][k] for k in fence_fields},sort_keys=True) for e in physical}
bodies={tuple((pose['body'],pose['revision']) for pose in e['data']['frame']['poses']) for e in physical}
occupied=[{'at_ms':relative(e),'tick':e['data']['frame']['tick'],'sequence':e['data']['frame']['control_state']['sequence'],'result':e['data']['frame']['control_state']['result'],'position':e['data']['frame']['poses'][0]['position']} for e in physical if e['data']['frame']['control_state']['result'].startswith('occupied(')]
dt=[b['timestamp']-a['timestamp'] for a,b in zip(frames,frames[1:])]
result={'recording_reason':observed['reason'],'movement_child_exit':child['exit'],'planned_cycles':42,'completed_cycles':action['completed_cycles'],'elapsed_seconds':action['elapsed_seconds'],'animation_frames':len(frames),'animation_ms':{'median':statistics.median(dt),'max':max(dt),'over_33':sum(d>33 for d in dt),'over_50':sum(d>50 for d in dt)},'network_events':dict(collections.Counter(e['data']['type'] for e in network['events'])),'control_results':dict(collections.Counter(r.get('result','missing') for r in network['responses'])),'control_response_capture_errors':sum('capture_error' in r for r in network['responses']),'clock_offset_spread_ms':max(offsets)-min(offsets),'physical_fence_count':len(fences),'body_identity_revision_sets':list(bodies),'renewals':projections,'control_failures':failures,'stationary_definition':'Consecutive animation-frame pairs with the same nonempty held-key set and horizontal position change <= 0.00001 metre; durations are observed sample bounds, not claims of exact onset/offset.','longest_stationary_ms':max((s['duration_ms'] for s in stops),default=0),'stationary_intervals_over_100ms':[s for s in stops if s['duration_ms']>=100],'native_occupied_results':occupied,'rotation_variants':len({tuple(f['rotation']) for f in frames}),'hidden_or_unfocused_frames':sum(f['hidden'] or not f['focused'] for f in frames),'held_at_end':observed['held'],'keys_released':action['release_completed'],'acceptance':'pending checks'}
checks={
 'complete_recording':observed['reason']=='complete' and child['exit']==0 and action['completed_cycles']==42,
 'keys_released':action['release_completed'] and not observed['held'],
 'visible':result['hidden_or_unfocused_frames']==0,
 'no_clear_floor_stall_100ms':not result['stationary_intervals_over_100ms'],
 'no_occupied_refusal':not occupied,
 'view_available':not any(result['network_events'].get(k,0) for k in ['refresh','unavailable']),
 'same_physical_fence':len(fences)==1,
 'same_body_revision':bodies=={((2,1),)},
 'renewal_while_moving':any(q['held'] for q in projections) and all(q['selection']=='active' for q in projections),
 'all_control_results_captured':result['control_response_capture_errors']==0 and 'missing' not in result['control_results']
}
result['checks']=checks
result['acceptance']='passed' if all(checks.values()) else 'not passed'
(p/'analysis.json').write_text(json.dumps(result,indent=2)+'\n')
(p/'stationary-intervals.json').write_text(json.dumps(stops,indent=2)+'\n')
print(json.dumps({k:result[k] for k in ['elapsed_seconds','animation_frames','network_events','control_results','longest_stationary_ms','acceptance']}))

if result['acceptance']!='passed':
    (p/'STOP-analysis.json').write_text(json.dumps({'failed_checks':[k for k,v in checks.items() if not v]},indent=2)+'\n')
    raise SystemExit(1)
