import test from 'node:test';
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
const entry=process.env.QUOD_O_ENTRY?pathToFileURL(process.env.QUOD_O_ENTRY):new URL('./analyze-campaign-O.mjs',import.meta.url);
const {analyze}=await import(entry);
const {flattenO}=await import(new URL('./coordinator-chronology.mjs',entry));
const epoch=1789070882000000000n,tid='a'.repeat(32),gid='c'.repeat(64);
const ns=n=>String(epoch+BigInt(n)*1000000n),sid=n=>String(n).padStart(16,'0');
const span=(id,name,lo,hi,parent=null,attributes={})=>({trace_id:tid,span_id:sid(id),
  parent:parent===null?null:sid(parent),name,start_ns:ns(lo),end_ns:ns(hi),attributes,
  resource:{'service.instance.id':'source'},links:[],events:[],dropped_events:0,dropped_attributes:0,dropped_links:0});
const event=(name,t,attributes={})=>({name,time_ns:ns(t),attributes});
const stage=(name,t)=>event('dtx.stage',t,{'quod.dtx.stage':name});
function fixture(){
  const s=span(3,'quod.dtx.coordinate',10,98,2,{'quod.namespace':'fixture','quod.dtx.group_id':gid,
    'quod.dtx.duration_scope':'owner_observed_attempt','quod.dtx.closure':'retirement_requested',
    'quod.dtx.ancestry':'retained_parent'});
  s.events=[stage('begin',10),stage('prepare_wave',20),stage('decision',30),stage('complete',40),
    event('dtx.completed',70),event('dtx.coordinator.close_observed',72),event('dtx.done_observed',75)];
  return {s,spans:[span(1,'quod.client.request',0,100),span(2,'quod.prolog.prove',0,10,1),s],
    results:[{request_id:'request-1',trace_id:tid,category:'pending',latency_ms:102}],
    inventory:{schema:'quod.coordinator-attempt-inventory/v1',
      provenance:{kind:'external_producer',reference:'synthetic independent-start input; not a hardware counter'},
      scope:{label:'O synthetic',complete:true},rows:[{allocation:'source',namespace:'fixture',group_id:gid,
        duration_scope:'owner_observed_attempt',expected_attempts:1}]}};
}
const run=f=>analyze(f.spans,f.results,f.inventory);
const kinds=r=>r.issues.map(i=>i.kind);
const phases=r=>r.groups[0].stages;
function excluded(r,reason){
  assert(kinds(r).includes(reason),`missing exclusion issue ${reason}`);
  assert.deepEqual(phases(r),[],'excluded root must not attribute any phase');
  assert.equal(r.groups.length,1,'excluded root retained');
  assert.equal(r.coordinator_inventory.summary.observed_roots,1,'inventory unchanged');
  assert.equal(r.coordinator_inventory.summary.expected_attempts,1);
  assert.equal(r.summary.attempts,1);assert.equal(r.requests[0].category,'pending');
  assert.equal(r.summary.attribution_denominator_ms,102);
  assert.equal(r.summary.excluded_coordinator_count,1);
  assert.deepEqual(r.summary.excluded_coordinator_keys,[`${tid}/${sid(3)}`]);
  assert(r.excluded_coordinators[0].reasons.includes(reason));
  assert.equal(r.summary.attribution_is_lower_bound,true);
  assert.equal(r.summary.full_gate_claim_permitted,false);
  assert.equal(r.summary.attributed_mean_ms,10);assert.equal(r.summary.residual_mean_ms,92);
}
function freeze(v){if(v&&typeof v==='object'){Object.freeze(v);for(const x of Object.values(v))freeze(x);}return v;}

test('chronological permutations preserve exact intervals and original objects',()=>{
  const f=fixture(),expected=phases(run(f)),requests=run(f).requests;
  assert.deepEqual(expected,[{stage:'dtx.begin',duration_ms:10},{stage:'dtx.prepare_wave',duration_ms:10},{stage:'dtx.decision',duration_ms:10}]);
  for(const order of [[6,5,4,3,2,1,0],[3,0,6,1,4,2,5],[0,1,2,3,4,5,6]]){
    const g=fixture();g.s.events=order.map(i=>g.s.events[i]);const before=JSON.stringify(g);freeze(g);
    const r=run(g);assert.deepEqual(phases(r),expected,'chronology must be wire-order independent');
    assert.deepEqual(r.requests,requests);assert.equal(JSON.stringify(g),before);
    assert.equal(r.summary.partial_coordinator_count,1);assert.equal(r.summary.excluded_coordinator_count,0);
    assert(kinds(r).includes('unterminated_group_stage'));
  }
});
test('one-nanosecond differences above safe integer range remain distinct',()=>{
  const f=fixture();f.s.events=[stage('begin',10),stage('prepare_wave',10),stage('complete',10)];
  f.s.events[1].time_ns=String(BigInt(f.s.events[0].time_ns)+1n);
  f.s.events[2].time_ns=String(BigInt(f.s.events[0].time_ns)+2n);f.s.events.reverse();
  assert.deepEqual(phases(run(f)),[{stage:'dtx.begin',duration_ms:.000001},{stage:'dtx.prepare_wave',duration_ms:.000001}]);
});
test('phase names never override the observed chronological order',()=>{
  const f=fixture();f.s.events=[stage('decision',10),stage('begin',20),stage('complete',40)];
  assert.deepEqual(phases(run(f)),[{stage:'dtx.decision',duration_ms:10},{stage:'dtx.begin',duration_ms:20}]);
});
test('equal-time stages exclude the root rather than use array order or zero-fill',()=>{
  for(const reverse of [false,true]){
    const f=fixture();f.s.events[1].time_ns=f.s.events[0].time_ns;if(reverse)f.s.events.reverse();
    excluded(run(f),'ambiguous_coordinator_event_order');
  }
});
test('repeated phase labels at equal time are still ambiguous, not deduplicated',()=>{
  const f=fixture();f.s.events.splice(1,0,structuredClone(f.s.events[0]));
  excluded(run(f),'ambiguous_coordinator_event_order');
});
test('repeated labels at distinct times do not invent a stage-name chronology',()=>{
  const f=fixture();f.s.events=[stage('begin',10),stage('begin',20),stage('complete',40)];
  assert.deepEqual(phases(run(f)),[{stage:'dtx.begin',duration_ms:10},{stage:'dtx.begin',duration_ms:20}]);
});
test('B observations at a stage timestamp never close it or resolve the tie',()=>{
  for(const name of ['dtx.completed','dtx.done_observed','dtx.coordinator.close_observed','dtx.worker_error']){
    const f=fixture();f.s.events=[stage('complete',10),event(name,10)];const r=run(f);
    excluded(r,'ambiguous_coordinator_event_order');assert(kinds(r).includes('unterminated_group_stage'));
  }
});
test('legacy completion is an endpoint only for legacy grammar, ties excluded',()=>{
  const f=fixture();for(const k of ['quod.dtx.duration_scope','quod.dtx.closure','quod.dtx.ancestry'])delete f.s.attributes[k];
  f.inventory.rows[0].duration_scope='legacy_child_process_lifetime';
  f.s.events=[event('dtx.completed',80),stage('begin',10),stage('complete',40)];
  const r=run(f);assert.deepEqual(phases(r),[{stage:'dtx.begin',duration_ms:30},{stage:'dtx.complete',duration_ms:40}]);
  assert.equal(r.groups[0].semantic_completion_observed,null);
  f.s.events[0].time_ns=ns(40);excluded(run(f),'ambiguous_coordinator_event_order');
});
test('invalid middle or final event cannot be skipped to bridge a phase',()=>{
  for(const invalid of [undefined,null,'',-1,'-1',1.5,'1.5','1e18','NaN','bad',Number.MAX_SAFE_INTEGER+2]){
    for(const index of [1,3]){
      const f=fixture();f.s.events[index].time_ns=invalid;
      excluded(run(f),'invalid_coordinator_event_timestamp');
    }
  }
});
test('final stage and non-endpoint observations are validated against span bounds',()=>{
  for(const index of [0,3,4,6]){
    const f=fixture();f.s.events[index].time_ns=ns(index===0?9:99);
    excluded(run(f),'coordinator_event_outside_span');
  }
});
test('invalid containing span retains root and refuses the unchanged exact audit',()=>{
  for(const [field,value] of [['start_ns','bad'],['end_ns',ns(9)],['end_ns',Number(ns(98))]]){
    const f=fixture();f.s[field]=value;const r=run(f);excluded(r,'invalid_coordinator_span_timestamp');
    assert.equal(r.groups[0].duration_ms,null);assert.equal(r.exact_audit.status,'not_run_invalid_span_timestamps');
    assert.equal(r.exact_audit.summary.structural_count_pass,false);
  }
});
test('unknown stage excludes all coordinator phases, including valid-looking neighbors',()=>{
  const f=fixture();f.s.events[1].attributes['quod.dtx.stage']='unknown';excluded(run(f),'unknown_group_stage');
});
test('O-A2 newest-event drops invalidate even a convincing retained stage prefix',()=>{
  for(const count of [1,'2']){
    const f=fixture();f.s.dropped_events=count;const r=run(f);excluded(r,'coordinator_dropped_events');
    assert(kinds(r).includes('dropped_group_metadata'));
  }
});
test('invalid drop counters cannot disguise missing events',()=>{
  for(const count of [null,'bad',-1,1.5,Number.MAX_SAFE_INTEGER+1]){
    const f=fixture();f.s.dropped_events=count;excluded(run(f),'invalid_coordinator_drop_count');
  }
});
test('O-A1 reports every excluded root with no request or attempt denominator shrink',()=>{
  const f=fixture();f.s.dropped_events=1;
  const other=structuredClone(f.s);other.span_id=sid(4);other.dropped_events=0;other.events[1].time_ns=other.events[0].time_ns;
  f.spans.push(other);f.inventory.rows[0].expected_attempts=3;
  const r=run(f);assert.equal(r.summary.excluded_coordinator_count,2);assert.equal(r.excluded_coordinators.length,2);
  assert.equal(r.groups.length,2);assert.equal(r.summary.attribution_denominator_ms,102);
  assert.equal(r.coordinator_inventory.summary.expected_attempts,3);assert.equal(r.coordinator_inventory.summary.observed_roots,2);
  assert.equal(r.coordinator_inventory.summary.missing_roots,1);assert.equal(r.requests.length,1);
  assert.equal(r.summary.attributed_percent,100*10/102);assert.equal(r.requests[0].phase_excluded_coordinator_keys.length,2);
});
test('missing client root still contributes its entire original duration',()=>{
  const f=fixture();f.spans=f.spans.filter(s=>s.name!=='quod.client.request');f.s.dropped_events=2;
  const r=run(f);assert.equal(r.requests.length,1);assert.equal(r.summary.attribution_denominator_ms,102);
  assert.equal(r.summary.attributed_mean_ms,0);assert.equal(r.summary.residual_mean_ms,102);
  assert.equal(r.excluded_coordinators.length,1);assert.equal(r.coordinator_inventory.summary.observed_roots,1);
});
function wire(s){return {resourceSpans:[{resource:{attributes:[{key:'service.instance.id',value:{stringValue:'source'}}]},scopeSpans:[{spans:[{
  traceId:s.trace_id,spanId:s.span_id,parentSpanId:s.parent,name:s.name,startTimeUnixNano:s.start_ns,endTimeUnixNano:s.end_ns,
  attributes:Object.entries(s.attributes).map(([key,v])=>({key,value:{stringValue:v}})),
  events:s.events.map(e=>({name:e.name,timeUnixNano:e.time_ns,attributes:Object.entries(e.attributes).map(([key,v])=>({key,value:{stringValue:v}}))})),
  droppedEventsCount:s.dropped_events}]}]}]};}
test('O ingestion keeps unsafe numeric timestamps visible before String conversion',()=>{
  const f=fixture(),doc=wire(f.s),raw=doc.resourceSpans[0].scopeSpans[0].spans[0];
  raw.events[1].timeUnixNano=Number(raw.events[1].timeUnixNano);const before=JSON.stringify(doc);freeze(doc);
  [f.spans[2]]=flattenO(doc);f.s=f.spans[2];
  assert.equal(typeof f.s.events[1].time_ns,'number');excluded(run(f),'invalid_coordinator_event_timestamp');
  assert.equal(JSON.stringify(doc),before);
});
test('O ingestion preserves SDK droppedEventsCount and exports an excluded root',()=>{
  const f=fixture();f.s.dropped_events=3;[f.spans[2]]=flattenO(wire(f.s));excluded(run(f),'coordinator_dropped_events');
});
test('malformed scope and ancestry exclusions are listed, not hidden by association filtering',()=>{
  const f=fixture();f.s.attributes['quod.dtx.duration_scope']='invalid';excluded(run(f),'unknown_coordinator_duration_scope');
  const g=fixture();g.s.attributes['quod.dtx.ancestry']='invalid';const r=run(g);
  assert(r.excluded_coordinators[0].reasons.includes('coordinator_ancestry_ineligible'));
  assert.equal(r.coordinator_inventory.summary.observed_roots,1);assert.equal(r.summary.attribution_denominator_ms,102);
});
