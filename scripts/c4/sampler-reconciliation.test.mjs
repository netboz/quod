import test from 'node:test';
import assert from 'node:assert/strict';
import {reconcileSampler} from './sampler-reconciliation.mjs';
const id=['00000000000000000000000000000001','0000000000000002'];
const start=(n,patch={})=>({window:'w',allocation:'a',vm:'v',owner:'p',group:'g',ordinal:String(n),...patch});
const obs=(sampled,patch={})=>({allocation_kind:'new_identity',parent_class:'parentless',
  sampler:{kind:sampled?'always_on':'always_off'},span:{identity:id,sampled,recording:sampled},...patch});
const run=starts=>reconcileSampler({starts,inventory_complete:true});

test('independent starts retain missing roots and replica/retry distinctions',()=>{
 const r=run([start(1),start(2),start(1,{allocation:'b'})]);
 assert.equal(r.denominator,3);assert.equal(r.excluded.length,3);
 assert.deepEqual(r.sampler_explained_missing_bounds,{lower:0,upper:3,denominator:3});
});
test('sampled missing root cannot be explained by the unsampled root policy',()=>{
 const observation=obs(true,{parent_class:'remote_sampled',parent:{identity:id,remote:true,sampled:true},sampler:{kind:'parent_based',branches:{
  root:{kind:'always_off'},remote_parent_sampled:{kind:'always_on'}}}});
 assert.deepEqual(run([start(1,{observation})]).sampler_explained_missing_bounds,{lower:0,upper:0,denominator:1});
});
test('observed policy exclusion and unknown starts give honest bounds',()=>{
 const r=run([start(1,{observation:obs(false)}),start(2)]);
 assert.deepEqual(r.sampler_explained_missing_bounds,{lower:1,upper:2,denominator:2});
});
test('sampler contradictions remain unknown, not policy attribution',()=>{
 const r=run([start(1,{observation:obs(false,{sampler:{kind:'always_on'}})})]);
 assert(r.rows[0].issues.includes('sampler_flag_disagreement'));
 assert.equal(r.sampler_explained_missing_bounds.lower,0);
});
test('record-only and borrowed-parent allocations remain distinct facts',()=>{
 const r=run([start(1,{observation:obs(false,{span:{identity:id,sampled:false,recording:true},sampler:{kind:'unknown'}})}),
  start(2,{observation:obs(true,{allocation_kind:'borrowed_parent'})})]);
 assert(r.rows[0].issues.includes('record_only'));
 assert(r.rows[1].issues.includes('allocation_borrowed_parent'));assert.equal(r.missing_roots,2);
});
test('O-A1/O-A2 keep dropped/tied roots in the denominator and excluded list',()=>{
 const r=reconcileSampler({starts:[start(1,{observation:obs(true)})],inventory_complete:true,
  roots:[{window:'w',allocation:'a',vm:'v',identity:id,dropped_events:'3',timestamp_ties:true}]});
 assert.equal(r.denominator,1);assert.equal(r.missing_roots,0);
 assert.deepEqual(r.excluded[0].reasons,['dropped_events','timestamp_ties']);
 assert.deepEqual(r.sampler_explained_missing_bounds,{lower:0,upper:0,denominator:0});
});
test('ordinal and drop counters cannot pass through unsafe Numbers',()=>{
 assert.throws(()=>run([start(1,{ordinal:9007199254740992})]),/invalid_ordinal/);
 assert.throws(()=>reconcileSampler({starts:[start(1,{observation:obs(true)})],roots:[
  {window:'w',allocation:'a',vm:'v',identity:id,dropped_events:9007199254740992}]}),/invalid_dropped/);
});
test('exact threshold comparison preserves low-bit trace IDs and equality',()=>{
 const sampler={kind:'trace_id_ratio',id_upper_bound:{encoding:'decimal_integer',value:'2'}};
 assert.equal(run([start(1,{observation:obs(true,{sampler})})]).rows[0].policy,'does_not_explain_absence');
 const equal=obs(false,{sampler,span:{identity:['00000000000000000000000000000002',id[1]],sampled:false,recording:false}});
 assert.equal(run([start(1,{observation:equal})]).rows[0].policy,'excludes_export');
 const binary64={kind:'trace_id_ratio',id_upper_bound:{encoding:'ieee754_binary64',value:'3ff0000000000000'}};
 assert.equal(run([start(1,{observation:obs(false,{sampler:binary64})})]).rows[0].policy,'excludes_export');
});
test('input trees are not mutated',()=>{
 const input={starts:[start(1,{observation:obs(true)})],roots:[]},before=structuredClone(input);
 const result=reconcileSampler(input);assert.deepEqual(input,before);
 result.rows[0].observation.span.sampled=false;assert.deepEqual(input,before);
});
test('one retrieved identity cannot prove two different starts exported',()=>{
 const r=reconcileSampler({starts:[start(1,{observation:obs(true)}),start(2,{observation:obs(true)})],
  roots:[{window:'w',allocation:'a',vm:'v',identity:id}],inventory_complete:true});
 assert.equal(r.missing_roots,2);assert.equal(r.excluded.length,2);
 assert.equal(r.sampler_explained_missing_bounds.upper,2);
});
test('wrong VM cannot match a root or silently shrink the denominator',()=>{
 const r=reconcileSampler({starts:[start(1,{observation:obs(true)})],roots:[{window:'w',allocation:'a',vm:'other',identity:id}]});
 assert.equal(r.missing_roots,1);assert.equal(r.orphan_roots.length,1);assert.equal(r.inventory_complete,false);
});
test('duplicate starts are refused and reused allocation identities are ambiguous',()=>{
 assert.throws(()=>run([start(1),start(1)]),/duplicate_independent_start/);
 const r=run([start(1,{observation:obs(false)}),start(2,{observation:obs(false)})]);
 assert(r.rows.every(r=>r.issues.includes('allocation_identity_reused')));
 assert.equal(r.sampler_explained_missing_bounds.lower,0);
});

test('a supplied parent class cannot override the observed parent flags',()=>{
 const observation=obs(false,{parent_class:'remote_unsampled',
  parent:{identity:id,remote:true,sampled:true},
  sampler:{kind:'parent_based',branches:{remote_parent_not_sampled:{kind:'always_off'}}}});
 const r=run([start(1,{observation})]);
 assert(r.rows[0].issues.includes('parent_class_disagreement'));
 assert.deepEqual(r.sampler_explained_missing_bounds,{lower:0,upper:1,denominator:1});
});
