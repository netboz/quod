// Synthetic offline tests. These are analyzer controls, not SDK/consensus tests.
import test from 'node:test';
import assert from 'node:assert/strict';
import {analyze} from './analyze-campaign-B.mjs';
import {analyze as baseline} from './analyze-campaign160.mjs';
import {audit} from './analyze-exact.mjs';
import {OWNER_SCOPE, LEGACY_SCOPE} from './coordinator-inventory.mjs';

const tid='a'.repeat(32),gid='c'.repeat(64),namespace='fixture';
const time=n=>String(BigInt(n)*1000000n);
const sid=n=>String(n).padStart(16,'0');
const key=n=>`${tid}/${sid(n)}`;
function span(id,name,start,end,parent=null,attributes={},allocation='source') {
  return {trace_id:tid,span_id:sid(id),parent:parent===null?null:sid(parent),name,
    start_ns:time(start),end_ns:time(end),attributes,resource:{'service.instance.id':allocation},
    links:[],events:[],dropped_attributes:0,dropped_events:0,dropped_links:0};
}
function root(id=3,closure='retirement_requested') {
  const s=span(id,'quod.dtx.coordinate',10,98,2,{'quod.namespace':namespace,
    'quod.dtx.group_id':gid,'quod.dtx.duration_scope':OWNER_SCOPE,'quod.dtx.closure':closure,
    'quod.dtx.ancestry':'retained_parent'});
  if(closure==='worker_exit')s.attributes['quod.dtx.exit_class']='normal';
  return s;
}
const event=(name,at,attributes={})=>({name,time_ns:time(at),attributes});
const phase=(stage,at)=>event('dtx.stage',at,{'quod.dtx.stage':stage});
const request=()=>({request_id:'request-1',trace_id:tid,category:'committed',latency_ms:102});
const ancestors=()=>[span(1,'quod.client.request',0,100),span(2,'quod.prolog.prove',0,10,1)];
function bucket(expected_attempts=1,duration_scope=OWNER_SCOPE,extra={}) {
  return {allocation:'source',namespace,group_id:gid,duration_scope,expected_attempts,...extra};
}
function inventory(rows=[bucket()],complete=true) {
  return {schema:'quod.coordinator-attempt-inventory/v1',
    provenance:{kind:'external_producer',reference:'synthetic producer admission fixture; not exporter enumeration'},
    scope:{label:'synthetic bounded attempt population',complete},rows};
}
const kinds=r=>r.issues.map(i=>i.kind);

test('B roots are owner_observed_attempt, never aliased to coordinator_total',()=>{
  const r=analyze([root()],[],inventory());
  assert.equal(r.groups[0].duration_scope,OWNER_SCOPE);
  assert.equal(r.groups[0].duration_ms,88);
  assert.match(r.groups[0].duration_meaning,/before child death/);
  assert.equal(r.groups[0].coordinator_total_ms,undefined);
  assert.equal(r.summary.full_gate_claim_permitted,false);
  assert.deepEqual(r.issues,[]);
});

test('legacy and B roots retain different meanings even at identical service version',()=>{
  const old=root(4);delete old.attributes['quod.dtx.duration_scope'];delete old.attributes['quod.dtx.closure'];
  delete old.attributes['quod.dtx.ancestry'];
  old.events=[event('dtx.completed',98,{'quod.dtx.result':'uncertain'})];
  const current=root();
  for(const s of [old,current])s.resource['service.version']='0.7.160';
  const r=analyze([old,current],[],inventory([bucket(),bucket(1,LEGACY_SCOPE)]));
  assert.deepEqual(r.groups.map(g=>g.duration_scope),[LEGACY_SCOPE,OWNER_SCOPE]);
  assert.equal(r.groups[0].semantic_completion_observed,null);
  assert.match(r.groups[0].completion_note,/failed\/uncertain/);
  assert.equal(r.coordinator_inventory.summary.expected_attempts,2);
  assert.equal(r.coordinator_inventory.summary.count_pass,true);
});

test('all finite closure/exit classes do not synthesize semantic completion',()=>{
  for(const closure of ['retirement_requested','start_failed','owner_terminating','worker_exit']) {
    for(const exit of closure==='worker_exit'?['normal','shutdown','killed','abnormal']:[null]) {
      const s=root(3,closure);if(exit)s.attributes['quod.dtx.exit_class']=exit;
      const r=analyze([s],[],inventory());
      assert.deepEqual(r.issues,[]);
      assert.equal(r.groups[0].closure,closure);
      assert.equal(r.groups[0].semantic_completion_observed,false);
    }
  }
});

test('unknown closure and arbitrary error-shaped exit data fail bounded schema checks',()=>{
  const s=root(3,'not_a_closure');
  assert(kinds(analyze([s],[],inventory())).includes('invalid_coordinator_closure'));
  s.attributes['quod.dtx.closure']='worker_exit';s.attributes['quod.dtx.exit_class']='exception_payload';
  assert(kinds(analyze([s],[],inventory())).includes('invalid_coordinator_exit_class'));
  s.attributes['quod.dtx.closure']='retirement_requested';s.attributes['quod.dtx.exit_class']='normal';
  assert(kinds(analyze([s],[],inventory())).includes('invalid_coordinator_exit_class'));
});

test('missing B scope tag is not silently treated as old-version meaning',()=>{
  const s=root();delete s.attributes['quod.dtx.duration_scope'];
  const r=analyze([s],[],inventory());
  assert.equal(r.groups[0].duration_scope,'unrecognized_duration_scope');
  assert(kinds(r).includes('unknown_coordinator_duration_scope'));
  assert(kinds(r).includes('missing_coordinator_roots'));
});

test('owner retirement and done_observed never invent the unfinished phase interval',()=>{
  const s=root();s.events=[phase('begin',10),phase('complete',40),event('dtx.done_observed',90)];
  const r=analyze([...ancestors(),s],[request()],inventory());
  assert.deepEqual(r.groups[0].stages,[{stage:'dtx.begin',duration_ms:30}]);
  assert.equal(r.groups[0].done_observed,true);
  assert.equal(r.groups[0].semantic_completion_observed,false);
  assert(kinds(r).includes('unterminated_group_stage'));
  assert.equal(r.summary.attributed_mean_ms,40);
  assert.equal(r.summary.residual_mean_ms,62);
});

test('child close decision is observed without bounding a phase or establishing Complete',()=>{
  const s=root(3,'worker_exit');
  s.events=[phase('prepare_wave',10),event('dtx.coordinator.close_observed',80,{'quod.dtx.result':'uncertain'})];
  const r=analyze([s],[],inventory());
  assert.deepEqual(r.groups[0].stages,[]);
  assert.equal(r.groups[0].coordinator_close_observed,true);
  assert.equal(r.groups[0].coordinator_closed_observed,undefined);
  assert.match(r.groups[0].coordinator_close_note,/not finished cleanup/);
  assert.equal(r.groups[0].semantic_completion_observed,false);
  assert(kinds(r).includes('unterminated_group_stage'));
});

test('semantic completion is separate from observed done and retirement provenance',()=>{
  const s=root();s.events=[phase('complete',10),event('dtx.completed',70),
    event('dtx.coordinator.close_observed',72),event('dtx.done_observed',75)];
  const r=analyze([s],[],inventory());
  assert.equal(r.groups[0].semantic_completion_observed,true);
  assert.equal(r.groups[0].done_observed,true);
  assert.equal(r.groups[0].closure,'retirement_requested');
  assert.equal(r.groups[0].coordinator_close_observed,true);
  assert.deepEqual(r.groups[0].stages,[]);
  assert(kinds(r).includes('unterminated_group_stage'));
});

test('worker-error observation is not a success or a child lifetime endpoint',()=>{
  const s=root(3,'owner_terminating');s.events=[phase('begin',10),event('dtx.worker_error',60)];
  const r=analyze([s],[],inventory());
  assert.equal(r.groups[0].worker_error_observed,true);
  assert.equal(r.groups[0].semantic_completion_observed,false);
  assert.deepEqual(r.groups[0].stages,[]);
  assert(kinds(r).includes('unterminated_group_stage'));
});

test('external inventory is required even when no roots exported',()=>{
  assert.throws(()=>analyze([],[]),/Explicit external producer/);
  const r=analyze([],[],inventory([bucket(3)]));
  assert.equal(r.coordinator_inventory.summary.expected_attempts,3);
  assert.equal(r.coordinator_inventory.summary.observed_roots,0);
  assert.equal(r.coordinator_inventory.summary.missing_roots,3);
  assert.match(r.issues.find(i=>i.kind==='missing_coordinator_roots').note,/never evidence of idleness/);
  assert.deepEqual(r.groups,[]);
});

test('deduplicated exported copies cannot fill a missing replacement attempt',()=>{
  const s=root();const r=analyze([s,s],[],inventory([bucket(2)]));
  assert.equal(r.coordinator_inventory.summary.observed_roots,1);
  assert.equal(r.coordinator_inventory.summary.missing_roots,1);
  assert.equal(r.coordinator_inventory.summary.count_pass,false);
});

test('same-group replacement attempts count separately; exact producer keys strengthen counts',()=>{
  const r=analyze([root(3),root(4)],[],inventory([bucket(2,OWNER_SCOPE,{expected_root_keys:[key(3),key(4)]})]));
  assert.equal(r.coordinator_inventory.summary.count_pass,true);
  assert.equal(r.coordinator_inventory.summary.exact_identity_check_complete,true);
  const mismatch=analyze([root(3),root(5)],[],inventory([bucket(2,OWNER_SCOPE,{expected_root_keys:[key(3),key(4)]})]));
  assert(kinds(mismatch).includes('coordinator_root_identity_mismatch'));
  assert.deepEqual(mismatch.coordinator_inventory.rows[0].missing_root_keys,[key(4)]);
});

test('count-only matching is labeled and never declares exact identity completeness',()=>{
  const r=analyze([root()],[],inventory());
  assert.equal(r.coordinator_inventory.summary.count_pass,true);
  assert.equal(r.coordinator_inventory.rows[0].identity_check,'count_only');
  assert.equal(r.coordinator_inventory.summary.exact_identity_check_complete,false);
  assert.equal(r.coordinator_inventory.summary.root_export_completeness_claim_permitted,false);
});

test('allocation/incarnation and group binding do not cross-fill missing roots',()=>{
  const s=root();s.resource['service.instance.id']='replacement-allocation';
  const r=analyze([s],[],inventory());
  assert(kinds(r).includes('missing_coordinator_roots'));
  assert(kinds(r).includes('coordinator_roots_outside_producer_inventory'));
  assert.equal(r.coordinator_inventory.summary.count_pass,false);
});

test('roots outside the inventory and excess roots fail instead of widening the population',()=>{
  assert(kinds(analyze([root()],[],inventory([]))).includes('coordinator_roots_outside_producer_inventory'));
  assert(kinds(analyze([root(3),root(4)],[],inventory())).includes('excess_coordinator_roots'));
});

test('incomplete producer observation cannot pass even with matching counts',()=>{
  const r=analyze([root()],[],inventory([bucket()],false));
  assert(kinds(r).includes('incomplete_coordinator_producer_inventory'));
  assert.equal(r.coordinator_inventory.summary.count_pass,false);
});

test('explicit bounded zero-attempt inventory is not inferred from an empty trace set',()=>{
  const r=analyze([],[],inventory([]));
  assert.equal(r.coordinator_inventory.summary.expected_attempts,0);
  assert.equal(r.coordinator_inventory.summary.count_pass,true);
  assert.equal(r.summary.full_gate_claim_permitted,false);
});

test('invalid producer inventory cannot masquerade as an empty population',()=>{
  const bads=[{}, {...inventory(),provenance:{kind:'exported_roots',reference:'not independent'}},
    inventory([bucket(-1)]),inventory([bucket(1.5)]),inventory([bucket(),bucket()]),
    inventory([bucket(1,'coordinator_total')]),inventory([bucket(2,OWNER_SCOPE,{expected_root_keys:[key(3)]})]),
    inventory([bucket(2,OWNER_SCOPE,{expected_root_keys:[key(3),key(3)]})])];
  for(const bad of bads)assert.throws(()=>analyze([],[],bad));
});

test('unsampled/disabled/lost roots remain missing evidence, not zero work',()=>{
  const r=analyze([...ancestors()],[request()],inventory());
  assert.equal(r.coordinator_inventory.summary.missing_roots,1);
  assert.equal(r.summary.residual_mean_ms,92);
  assert.equal(r.summary.numerical_95_percent,false);
});

test('canceled probe and absent page parent discrepancies exactly match unchanged auditor',()=>{
  const F='quod.foreign.';
  const collection=span(4,F+'probe_collection',15,30,3,{[F+'expected_probe_children']:1});
  const admission=span(6,F+'page_admission',20,20,5,{[F+'page_id']:'page-1',[F+'page_expected_terminal']:1});
  const terminal=span(7,F+'page_completion_owner',30,30,5,{[F+'page_id']:'page-1',
    [F+'page_terminal_count']:1,[F+'page_terminal']:'cancelled'});
  const input=[root(),collection,admission,terminal];
  const r=analyze(input,[],inventory());
  assert.deepEqual(r.exact_audit,audit(input));
  assert(r.exact_audit.issues.some(i=>i.kind==='probe_export_count_or_sequence'));
  assert(r.exact_audit.issues.some(i=>i.kind==='page_admission_terminal_count'));
  assert.equal(r.exact_audit.probe_collections[0].child_union.attributed_union_ms,0);
  assert.equal(r.exact_audit.probe_collections[0].child_union.residual_ms,15);
  assert.equal(r.exact_audit.pages[0].page,null);
  assert.equal(r.summary.full_gate_claim_permitted,false);
});

test('late child event outside ended owner root is not used to expand the root interval',()=>{
  const s=root();s.events=[phase('complete',10),event('dtx.coordinator.close_observed',110)];
  const r=analyze([s],[],inventory());
  assert(kinds(r).includes('unterminated_group_stage'));
  assert.deepEqual(r.groups[0].stages,[]);
  assert.equal(r.groups[0].duration_ms,88);
});

test('cross-allocation coordinate phases remain excluded from source client attribution',()=>{
  const s=root();s.resource['service.instance.id']='remote';
  s.events=[phase('begin',10),phase('decision',60),event('dtx.coordinator.close_observed',98)];
  const r=analyze([...ancestors(),s],[request()],inventory([bucket(1,OWNER_SCOPE,{allocation:'remote'})]));
  assert.equal(r.summary.attributed_mean_ms,10);
  assert.equal(r.requests[0].remote_groups_excluded.length,1);
  assert.deepEqual(r.groups[0].stages,[{stage:'dtx.begin',duration_ms:50}]);
});

test('dropped owner metadata remains an auditor issue including links',()=>{
  for(const field of ['dropped_attributes','dropped_events','dropped_links']) {
    const s=root();s[field]=1;
    assert(kinds(analyze([s],[],inventory())).includes('dropped_group_metadata'));
  }
});

test('baseline controls: old analyzer misses total root loss and has no duration meaning',()=>{
  const before=baseline([],[]),after=analyze([],[],inventory([bucket(2)]));
  assert.equal(before.issues.length,0);
  assert.equal(before.coordinator_inventory,undefined);
  assert(kinds(after).includes('missing_coordinator_roots'));
  assert.equal(baseline([root()],[]).groups[0].duration_scope,undefined);
  assert.equal(analyze([root()],[],inventory()).groups[0].duration_scope,OWNER_SCOPE);
});

test('baseline control: old completion assumption rejects legitimate owner retirement',()=>{
  const s=root();
  assert(baseline([s],[]).issues.some(i=>i.kind==='missing_group_completion_event'));
  assert.deepEqual(analyze([s],[],inventory()).issues,[]);
});

test('amendment: tentative starts lost on callback unwind remain in the independent denominator',()=>{
  // Synthetic callback producer, not a Quod VM or SDK unwind reproduction.
  const producerKeys=[];
  const start=()=>producerKeys.push(key(producerKeys.length+3));
  const unwind=new Error('synthetic_callback_unwind');
  assert.throws(()=>{start();start();throw unwind;},e=>e===unwind);
  const r=analyze([],[],inventory([bucket(producerKeys.length,OWNER_SCOPE,{expected_root_keys:producerKeys})]));
  assert.equal(r.coordinator_inventory.summary.expected_attempts,2);
  assert.equal(r.coordinator_inventory.summary.missing_roots,2);
  assert.equal(r.issues.find(i=>i.kind==='missing_coordinator_roots').cause,'unknown');
  assert.deepEqual(r.coordinator_inventory.rows[0].missing_root_keys,producerKeys);
  assert.deepEqual(r.groups,[]); // no fabricated interval, ancestry or closure
});

test('amendment: independently verified unwind evidence is retained, not inferred as a missing-root cause',()=>{
  const e={root_key:key(3),callback_unwind:{verified:true,reference:'synthetic producer fixture: later callback failure'}};
  const r=analyze([],[],inventory([bucket(1,OWNER_SCOPE,{expected_root_keys:[key(3)],attempt_evidence:[e]})]));
  const observed=r.coordinator_inventory.rows[0].attempt_evidence[0];
  assert.deepEqual(observed.callback_unwind,e.callback_unwind);
  assert.equal(observed.root_observed,false);
  assert.equal(observed.missing_root_cause,'unknown');
  assert.equal(r.coordinator_inventory.summary.missing_roots,1);
  assert.equal(r.coordinator_inventory.summary.count_pass,false);
  assert.deepEqual(r.groups,[]);
});

test('amendment: callback_unwind is not a fabricated owner-release closure class',()=>{
  assert(kinds(analyze([root(3,'callback_unwind')],[],inventory())).includes('invalid_coordinator_closure'));
});

test('amendment: a reported callback unwind does not require or infer root loss',()=>{
  const e={root_key:key(3),callback_unwind:{verified:true,reference:'synthetic unwind after already observed release'}};
  const r=analyze([root()],[],inventory([bucket(1,OWNER_SCOPE,{expected_root_keys:[key(3)],attempt_evidence:[e]})]));
  assert.equal(r.coordinator_inventory.summary.count_pass,true);
  assert.equal(r.coordinator_inventory.rows[0].attempt_evidence[0].root_observed,true);
  assert.equal(r.coordinator_inventory.rows[0].attempt_evidence[0].missing_root_cause,null);
  assert.equal(r.groups[0].closure,'retirement_requested');
});

test('amendment: genuinely parentless history/rebuilt rows have the same honest ancestry class',()=>{
  for(const parent of [null,sid(0)]) {
    const s=root();s.parent=parent;s.attributes['quod.dtx.ancestry']='no_retained_parent';
    const r=analyze([s],[],inventory());
    assert.deepEqual(r.issues,[]);
    assert.equal(r.groups[0].ancestry_class,'no_retained_parent');
    assert.equal(r.groups[0].ancestry_origin,'not_inferred');
    assert.match(r.groups[0].ancestry_note,/History-only recovery or a rebuilt owner row/);
    assert.equal(r.groups[0].duration_scope,OWNER_SCOPE);
  }
});

test('amendment: retained-parent class does not assert that an unexported parent is a client caller',()=>{
  const r=analyze([root()],[],inventory());
  assert.equal(r.groups[0].ancestry_class,'retained_parent');
  assert.equal(r.groups[0].ancestry_origin,'not_inferred');
  assert.match(r.groups[0].ancestry_note,/not by itself proof of a client caller/);
});

test('amendment: same group and trace cannot restore a caller to a parentless post-DOWN attempt',()=>{
  const old=root(),rebuilt=root(4);rebuilt.parent=null;
  rebuilt.attributes['quod.dtx.ancestry']='no_retained_parent';
  rebuilt.events=[phase('begin',10),phase('decision',60),event('dtx.completed',98)];
  const r=analyze([...ancestors(),old,rebuilt],[request()],inventory([bucket(2)]));
  assert.equal(r.summary.attributed_mean_ms,10);
  assert.deepEqual(r.requests[0].group_keys,[key(3)]);
  assert.equal(r.groups[1].ancestry_class,'no_retained_parent');
  assert.equal(r.groups[1].ancestry_origin,'not_inferred');
  assert.deepEqual(r.groups[1].stages,[{stage:'dtx.begin',duration_ms:50}]);
});

test('amendment: an ambient parent contradicting no_retained_parent cannot be used for attribution',()=>{
  const s=root();s.attributes['quod.dtx.ancestry']='no_retained_parent';
  s.events=[phase('begin',10),phase('decision',60),event('dtx.completed',98)];
  const r=analyze([...ancestors(),s],[request()],inventory());
  assert(kinds(r).includes('coordinator_ancestry_parent_mismatch'));
  assert.equal(r.groups[0].ancestry_association_eligible,false);
  assert.equal(r.summary.attributed_mean_ms,10);
  assert.deepEqual(r.requests[0].group_keys,[]);
  assert.deepEqual(r.groups[0].stages,[{stage:'dtx.begin',duration_ms:50}]);
});

test('amendment: retained_parent without a valid actual parent is flagged',()=>{
  for(const parent of [null,sid(0),'not-a-span-id']) {
    const s=root();s.parent=parent;
    assert(kinds(analyze([s],[],inventory())).includes('coordinator_ancestry_parent_mismatch'));
  }
});

test('amendment: missing or over-specific ancestry declarations are not repaired from parent fields',()=>{
  for(const declared of [undefined,'history_only','post_down_rebuild']) {
    const s=root();s.attributes['quod.dtx.ancestry']=declared;
    const r=analyze([s],[],inventory());
    assert(kinds(r).includes('missing_or_invalid_coordinator_ancestry'));
    assert.equal(r.groups[0].ancestry_class,'unknown');
    assert.equal(r.groups[0].ancestry_association_eligible,false);
  }
});

test('amendment: only verified exact-attempt inventory provenance names history versus post-DOWN rebuild',()=>{
  for(const basis of ['history_only','post_down_rebuild']) {
    const s=root();s.parent=null;s.attributes['quod.dtx.ancestry']='no_retained_parent';
    const e={root_key:key(3),ancestry:{class:'no_retained_parent',basis,verified:true,
      reference:`synthetic independent producer fixture: ${basis}`}};
    const r=analyze([s],[],inventory([bucket(1,OWNER_SCOPE,{expected_root_keys:[key(3)],attempt_evidence:[e]})]));
    assert.deepEqual(r.issues,[]);
    assert.equal(r.coordinator_inventory.rows[0].attempt_evidence[0].ancestry.basis,basis);
    assert.equal(r.groups[0].ancestry_origin,'not_inferred');
    assert.equal(r.groups[0].ancestry_class,'no_retained_parent');
  }
});

test('amendment: contradictory independent ancestry is an explicit inventory discrepancy',()=>{
  const e={root_key:key(3),ancestry:{class:'no_retained_parent',basis:'post_down_rebuild',verified:true,
    reference:'synthetic contradictory producer evidence'}};
  const r=analyze([root()],[],inventory([bucket(1,OWNER_SCOPE,{expected_root_keys:[key(3)],attempt_evidence:[e]})]));
  assert(kinds(r).includes('coordinator_ancestry_evidence_mismatch'));
  assert.equal(r.coordinator_inventory.summary.count_pass,false);
});

test('amendment: per-attempt evidence needs verification, references and exact producer binding',()=>{
  const cases=[
    {root_key:key(4),callback_unwind:{verified:true,reference:'wrong attempt'}},
    {root_key:key(3),callback_unwind:{verified:false,reference:'not verified'}},
    {root_key:key(3),callback_unwind:{verified:true,reference:''}},
    {root_key:key(3),ancestry:{class:'no_retained_parent',basis:'post_down_rebuild',verified:false,reference:'not verified'}},
    {root_key:key(3),ancestry:{class:'retained_parent',basis:'post_down_rebuild',verified:true,reference:'contradictory basis'}},
    {root_key:key(3)}
  ];
  for(const e of cases)assert.throws(()=>analyze([],[],inventory([bucket(1,OWNER_SCOPE,
    {expected_root_keys:[key(3)],attempt_evidence:[e]})])));
  const e={root_key:key(3),callback_unwind:{verified:true,reference:'bound only with independent root key'}};
  assert.throws(()=>analyze([],[],inventory([bucket(1,OWNER_SCOPE,{attempt_evidence:[e]})])));
});

test('causal: B completed preserves semantic observation but cannot end the final child stage',()=>{
  const s=root();s.events=[phase('begin',10),phase('complete',40),event('dtx.completed',90)];
  const r=analyze([...ancestors(),s],[request()],inventory());
  assert.equal(r.groups[0].semantic_completion_observed,true);
  assert.deepEqual(r.groups[0].stages,[{stage:'dtx.begin',duration_ms:30}]);
  assert(kinds(r).includes('unterminated_group_stage'));
  assert.equal(r.summary.attributed_mean_ms,40);
  assert.equal(r.summary.residual_mean_ms,62);
});

test('causal: legacy completed event retains the original phase-end grammar and ambiguous semantics',()=>{
  const s=root();
  for(const k of ['quod.dtx.duration_scope','quod.dtx.closure','quod.dtx.ancestry'])delete s.attributes[k];
  s.events=[phase('begin',10),phase('complete',40),event('dtx.completed',90)];
  const r=analyze([...ancestors(),s],[request()],inventory([bucket(1,LEGACY_SCOPE)]));
  assert.deepEqual(r.groups[0].stages,[{stage:'dtx.begin',duration_ms:30},{stage:'dtx.complete',duration_ms:50}]);
  assert.equal(r.groups[0].semantic_completion_observed,null);
  assert.equal(r.summary.attributed_mean_ms,90);
  assert.deepEqual(r.issues,[]);
});

test('causal: obsolete draft coordinator_closed neither aliases close_observed nor bounds a stage',()=>{
  const s=root();s.events=[phase('complete',10),event('dtx.coordinator_closed',90)];
  const r=analyze([s],[],inventory());
  assert.equal(r.groups[0].coordinator_close_observed,false);
  assert.deepEqual(r.groups[0].stages,[]);
  assert(kinds(r).includes('obsolete_coordinator_close_event'));
  assert(kinds(r).includes('unterminated_group_stage'));
});

test('causal: neither B observation zero-fills a child interval when its timestamp equals stage start',()=>{
  for(const name of ['dtx.completed','dtx.coordinator.close_observed']) {
    const s=root();s.events=[phase('complete',10),event(name,10)];
    const r=analyze([...ancestors(),s],[request()],inventory());
    assert.deepEqual(r.groups[0].stages,[]);
    assert(kinds(r).includes('unterminated_group_stage'));
    assert.equal(r.summary.attributed_mean_ms,10);
    assert.equal(r.summary.residual_mean_ms,92);
  }
});
