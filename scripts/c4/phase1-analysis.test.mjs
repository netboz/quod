import test from 'node:test';import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {startInventory,analyzePhase1} from './phase1-analysis.mjs';
const group='01'.repeat(32),trace='01'.repeat(16),span='02'.repeat(8);
const ns='n',owner='<0.1.0>',digest=createHash('sha256').update(ns).digest('hex');
const native={stage:'native_start',namespace:ns,owner,group,ordinal:'1',monotonic_ns:'10'};
const metadata={sampler:{kind:'always_on'},parent:{identity:'none'},parent_class:'parentless',
 allocation_kind:'new_identity',span:{identity:[trace,span],sampled:true,recording:true,remote:false}};
const allocated={stage:'allocation',window:'w',group,namespace_digest:digest,owner,trace_owner:owner,
 edge:'returned',monotonic_ns:'11',metadata};
const capture=(records=[native,allocated])=>({label:'w',allocation:'a',vm:'v',records,
 scope_complete:true,issues:[],trace_delivered:true,session_removed:true,collector_dead:true,
 owner_monitors_removed:true,trace_flags_removed:true,native_start_count:1,received_start_count:1,assigned_start_count:1});
const attr=(key,value)=>({key,value:{stringValue:value}});
const root=(patch={})=>({traceId:trace,spanId:span,name:'quod.dtx.coordinate',
 startTimeUnixNano:'100',endTimeUnixNano:'1000',attributes:[
 attr('quod.dtx.duration_scope','owner_observed_attempt'),attr('quod.dtx.group_id',group)],
 events:[{name:'dtx.stage',timeUnixNano:'800',attributes:[attr('quod.dtx.stage','prepare_wave')]},
 {name:'dtx.stage',timeUnixNano:'200',attributes:[attr('quod.dtx.stage','begin')]}],...patch});
const doc=(spans,allocation='a')=>({resourceSpans:[{resource:{attributes:[attr('service.instance.id',allocation)]},scopeSpans:[{spans}]}]});
test('real-shaped records join exact allocation and O sorts reverse wire chronology',()=>{
 const r=analyzePhase1({captures:[capture()],traces:[doc([root()])]});
 assert.equal(r.inventory.inventory_complete,true);assert.equal(r.sampler.denominator,1);
 assert.equal(r.sampler.missing_roots,0);assert.deepEqual(r.timelines[0].stages,[{stage:'dtx.begin',interval_ns:['200','800']}]);
});
test('missing allocation metadata retains an unknown independent start',()=>{
 const r=analyzePhase1({captures:[capture([native])],traces:[]});
 assert.equal(r.sampler.denominator,1);assert.equal(r.excluded_attempt_count,1);
 assert.deepEqual(r.sampler.sampler_explained_missing_bounds,{lower:0,upper:1,denominator:1});
});
test('observed policy exclusions are distinct from missing sampled roots',()=>{
 const off=structuredClone(allocated);off.metadata.sampler.kind='always_off';
 off.metadata.span.sampled=false;off.metadata.span.recording=false;
 const r=analyzePhase1({captures:[capture([native,off])],traces:[]});
 assert.deepEqual(r.sampler.sampler_explained_missing_bounds,{lower:1,upper:1,denominator:1});
});
test('native mismatch and owner-loss flags never become a complete denominator',()=>{
 const c=capture();c.native_start_count=2;
 assert.equal(startInventory([c]).inventory_complete,false);
 c.native_start_count=1;c.owner_monitors_removed=false;
 assert.equal(startInventory([c]).inventory_complete,false);
});
test('wrong-owner/group/namespace metadata is unassigned, never attached by timestamp',()=>{
 for(const change of [{owner:'wrong'},{group:'03'.repeat(32)},{namespace_digest:'00'.repeat(32)}]){
  const r=startInventory([capture([native,{...allocated,...change}])]);
  assert.equal(r.inventory_complete,false);assert.equal(r.starts[0].observation,undefined);
 }
});
test('duplicate metadata cannot select its preferred flags',()=>{
 const r=startInventory([capture([native,allocated,allocated])]);
 assert.equal(r.starts[0].observation,undefined);
 assert.deepEqual(r.starts[0].metadata_issues,['duplicate_allocation_metadata']);
});
test('O-A1/A2 retain tied and dropped roots while excluding phase intervals',()=>{
 const tied=root({droppedEventsCount:'2'});tied.events[1].timeUnixNano='800';
 const r=analyzePhase1({captures:[capture()],traces:[doc([tied])]});
 assert.equal(r.sampler.denominator,1);assert.equal(r.sampler.missing_roots,0);
 assert.equal(r.excluded_coordinator_count,1);assert.equal(r.excluded_attempt_count,1);
 assert.deepEqual(r.timelines[0].stages,[]);
});
test('shared quorum work is not mislabeled atomic-only, cross-node clocks excluded',()=>{
 const child={traceId:trace,spanId:'03'.repeat(8),parentSpanId:span,name:'quod.dtx.quorum.probe',
  startTimeUnixNano:'300',endTimeUnixNano:'400'};
 const r=analyzePhase1({captures:[capture()],traces:[doc([root(),child])]});
 assert.equal(r.timelines[0].ordinary_descendants[0].component,'shared-with-L2');
 const remote=analyzePhase1({captures:[capture()],traces:[doc([root()]),doc([child],'b')]});
 assert.deepEqual(remote.timelines[0].ordinary_descendants[0].excluded_reasons,['cross_allocation_clock']);
});
test('unsafe timestamps, hot Phase-2 records, repeated inventories are refused',()=>{
 assert.throws(()=>startInventory([capture([{...native,monotonic_ns:10}])]),/invalid_native_time/);
 assert.throws(()=>startInventory([capture([{stage:'owner_turn'}])]),/phase2/);
 assert.throws(()=>startInventory([capture(),capture()]),/duplicate_capture/);
});
test('input trees remain byte-equivalent',()=>{
 const input={captures:[capture()],traces:[doc([root()])]},before=structuredClone(input);
 analyzePhase1(input);assert.deepEqual(input,before);
});
