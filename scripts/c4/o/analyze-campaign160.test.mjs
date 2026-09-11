import test from 'node:test';
import assert from 'node:assert/strict';
import {analyze,partition} from './analyze-campaign160.mjs';
const tid='a'.repeat(32),other='b'.repeat(32);
const time=n=>String(BigInt(n)*1000000n);
function span(id,name,start,end,parent=null,attributes={},allocation='source',trace=tid){
  return{trace_id:trace,span_id:String(id).padStart(16,'0'),parent:parent===null?null:String(parent).padStart(16,'0'),
    name,start_ns:time(start),end_ns:time(end),attributes,resource:{'service.instance.id':allocation},
    links:[],events:[],dropped_attributes:0,dropped_events:0,dropped_links:0};
}
const row=(latency=102,trace_id=tid)=>({request_id:'request-1',trace_id,category:'committed',latency_ms:latency});
const root=()=>span(1,'quod.client.request',0,100);
const coordinate=(allocation='source')=>{
  const s=span(3,'quod.dtx.coordinate',10,98,2,{'quod.dtx.group_id':'c'.repeat(64)},allocation);
  s.events=[{name:'dtx.stage',time_ns:time(10),attributes:{'quod.dtx.stage':'begin'}},
    {name:'dtx.stage',time_ns:time(40),attributes:{'quod.dtx.stage':'decision'}},
    {name:'dtx.completed',time_ns:time(98),attributes:{'quod.dtx.result':'ok'}}];return s;
};
test('old untraced L3 wait is residual, not automatically attributed outside prove',()=>{
  const r=analyze([root(),span(2,'quod.prolog.prove',0,10,1),span(3,'quod.prolog.public_proof',0,100,1)],[row()]);
  assert.equal(r.summary.attributed_mean_ms,10);assert.equal(r.summary.residual_mean_ms,92);
  assert.equal(r.summary.numerical_95_percent,false);
});
test('group events close a same-owner phase partition with no marginal quantiles',()=>{
  const r=analyze([root(),span(2,'quod.prolog.prove',0,10,1),coordinate()],[row()]);
  assert.deepEqual(r.requests[0].buckets_ms,{proof_owner:10,'dtx.begin':30,'dtx.decision':58,unknown:2,client_boundary_unknown:2});
  assert.equal(r.summary.attributed_mean_ms,98);assert.equal(r.summary.residual_mean_ms,4);
  assert.equal(r.summary.numerical_95_percent,true);assert.equal(r.summary.full_gate_claim_permitted,false);
});
test('parallel and nested intervals are unioned, not added twice',()=>{
  assert.deepEqual(partition(0n,10000000n,[{lo:0n,hi:7000000n,stage:'a'},{lo:3000000n,hi:10000000n,stage:'b'}]),
    {a:3,'overlap:a+b':4,b:3});
});
test('cross-node coordinate excluded even with causal parent and same trace',()=>{
  const r=analyze([root(),span(2,'quod.prolog.prove',0,10,1),coordinate('remote')],[row()]);
  assert.equal(r.summary.attributed_mean_ms,10);assert.equal(r.requests[0].remote_groups_excluded.length,1);
});
test('missing request trace and pending are included in the campaign denominator',()=>{
  const missing={...row(1000,other),category:'pending',request_id:'request-2'};
  const r=analyze([root(),span(2,'quod.prolog.prove',0,10,1)],[row(),missing]);
  assert.equal(r.summary.attempts,2);assert.equal(r.summary.observed_mean_ms,551);
  assert.equal(r.summary.attributed_mean_ms,5);assert.equal(r.summary.residual_mean_ms,546);
  assert.equal(r.requests[1].category,'pending');
});
test('queue expected counts, predecessor missing link and infinity are audited',()=>{
  const residence=span(3,'quod.foreign.caller_residence',0,10,2,{'quod.owner.blockers_expected':1});
  const marker=span(4,'quod.foreign.queue_blocker',1,1,3,{'quod.owner.blocker_ordinal':1,
    'quod.owner.blocker':'active','quod.owner.blocker_job_id':'job','quod.owner.blocker_trace_available':true});
  marker.links=[{trace_id:other,span_id:'0000000000000009',attributes:{}}];
  const stage=span(5,'quod.foreign.owner_stage',0,10,3,{'quod.caller.budget_kind':'infinity','quod.owner.stage':'queued'});
  const r=analyze([residence,marker,stage],[]);
  assert.equal(r.queue[0].count_pass,true);assert.equal(r.queue[0].blockers[0].predecessor_unknown,true);
  assert.deepEqual(r.queue[0].queue_stages[0].blocker_union_ms,{unknown:1,'["active","job",null]':9});
  assert.deepEqual(r.unresolved_predecessor_trace_ids,[other]);assert.equal(r.issues.length,0);
  const bad=analyze([residence],[]);assert(bad.issues.some(i=>i.kind==='queue_blocker_count_or_sequence'));
  stage.attributes['quod.caller.remaining_ms']=30;
  assert(analyze([residence,marker,stage],[]).issues.some(i=>i.kind==='invalid_budget_observation'));
});
test('replay span copies deduplicate and a missing group end never manufactures duration',()=>{
  const replay=span(5,'quod.foreign.cache_replay',0,7);
  const c=coordinate();c.events.pop();
  const r=analyze([root(),span(2,'quod.prolog.prove',0,10,1),c,replay,replay],[row()]);
  assert.equal(r.replay.replay_stage_count,1);assert.equal(r.replay.replay_elapsed_sum_ms,7);
  assert(r.issues.some(i=>i.kind==='unterminated_group_stage'));assert.equal(r.summary.attributed_mean_ms,40);
});
