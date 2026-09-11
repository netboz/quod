import {reconcileSampler} from './sampler-reconciliation.mjs';
import {flattenO,coordinatorChronology,spanBounds,exactNonnegative} from './o/coordinator-chronology.mjs';
import {OWNER_SCOPE} from './o/coordinator-inventory.mjs';
import {createHash} from 'node:crypto';
const key=r=>JSON.stringify([r.window,r.allocation,r.vm,r.owner,r.group,r.ordinal]);
const mono=t=>{if(typeof t!=='string'||!/^-(?:[1-9][0-9]*)$|^(?:0|[1-9][0-9]*)$/.test(t))throw Error('invalid_native_time');return BigInt(t);};
function count(v){if(!Number.isSafeInteger(v)||v<0)throw Error('invalid_capture_count');return v;}
function component(s) {
 if(s.name.startsWith('quod.foreign.'))return 'shared-with-L2';
 if(['quod.dtx.wave','quod.dtx.wave.item'].includes(s.name))return 'L3-only';
 if(s.name.startsWith('quod.dtx.quorum.'))return 'shared-with-L2';
 return 'unresolved';
}

// Consume original capture records, never derive the start denominator from
// exported spans. No completeness upgrade based on a sampler assumption.
export function startInventory(captures) {
 const starts=[],issues=[],seen=new Set();let complete=true;
 for(const c of captures) {
   const scope={window:c.label,allocation:c.allocation,vm:c.vm};
   for(const value of Object.values(scope))if(typeof value!=='string'||!value.length)throw Error('missing_capture_scope');
   const sk=JSON.stringify(scope);if(seen.has(sk))throw Error('duplicate_capture');seen.add(sk);
   const records=structuredClone(c.records),current=new Map(),counts=new Map(),local=[];
   if(!Array.isArray(records))throw Error('missing_capture_records');
   for(const r of records) {
     if(r.stage==='native_start') {
       if(!/^[0-9a-f]{64}$/.test(r.group)||typeof r.owner!=='string'||!r.owner.length||
          typeof r.namespace!=='string'||!r.namespace.length)throw Error('invalid_start_identity');
       const group=JSON.stringify([r.owner,r.group]),n=(counts.get(group)??0)+1;
       if(r.ordinal!==String(n))throw Error('noncontiguous_start_ordinals');counts.set(group,n);
       mono(r.monotonic_ns);
       const s={...scope,owner:r.owner,group:r.group,ordinal:r.ordinal,namespace:r.namespace,
         start_monotonic_ns:r.monotonic_ns,metadata_issues:[]};
       starts.push(s);local.push(s);current.set(r.owner,s);
     } else if(r.stage==='allocation') {
       const s=current.get(r.trace_owner);
       if(!s||r.owner!==s.owner||r.group!==s.group||r.window!==scope.window||
          r.namespace_digest!==createHash('sha256').update(s.namespace).digest('hex')||
          mono(r.monotonic_ns)<mono(s.start_monotonic_ns)) {
         issues.push({scope,kind:'unmatched_allocation_record'});complete=false;continue;
       }
       if(s.allocation_seen){delete s.observation;s.metadata_issues.push('duplicate_allocation_metadata');continue;}
       s.allocation_seen=true;s.allocation_edge=r.edge;
       if(r.edge==='returned')s.observation=r.metadata;
       else s.metadata_issues.push(r.edge==='unwind'?'allocation_unwind':'unknown_allocation_edge');
     } else throw Error('phase2_or_unknown_record_in_phase1');
   }
   const clean=c.scope_complete===true&&Array.isArray(c.issues)&&c.issues.length===0&&
     c.trace_delivered===true&&c.session_removed===true&&c.collector_dead===true&&
     c.owner_monitors_removed===true&&c.trace_flags_removed===true&&
     count(c.native_start_count)===local.length&&count(c.received_start_count)===local.length&&
     count(c.assigned_start_count)===local.length;
   if(!clean){complete=false;issues.push({scope,kind:'capture_incomplete',reported:c.issues??null});}
 }
 return {starts,inventory_complete:complete&&captures.length>0,issues};
}

export function analyzePhase1({captures,traces}) {
 const inventory=startInventory(captures),roots=[],timelines=[],spans=[],issues=[...inventory.issues];
 const byAlloc=new Map();
 for(const c of captures){if(byAlloc.has(c.allocation))throw Error('multiple_windows_per_allocation');byAlloc.set(c.allocation,c);}
 for(const doc of traces)spans.push(...flattenO(doc));
 const byId=new Map();
 for(const s of spans){const k=s.trace_id+'/'+s.span_id;
   if(byId.has(k)&&JSON.stringify(byId.get(k))!==JSON.stringify(s))throw Error('conflicting_span_copy');
   byId.set(k,s);
 }
 function descendant(s,root){const visited=new Set();while(s){const k=s.trace_id+'/'+s.span_id;
   if(k===root.trace_id+'/'+root.span_id)return true;if(visited.has(k))return false;
   visited.add(k);s=byId.get(s.trace_id+'/'+s.parent);
 }return false;}
 for(const root of byId.values()) {
   if(root.name!=='quod.dtx.coordinate')continue;
   const allocation=root.resource['service.instance.id'],capture=byAlloc.get(allocation);
   if(!capture){issues.push({kind:'root_outside_capture_allocation',identity:[root.trace_id,root.span_id]});continue;}
   const chronology=coordinatorChronology(root,OWNER_SCOPE),bounds=spanBounds(root);
   const dropped=exactNonnegative(root.dropped_events??0);
   if(dropped===null)throw Error('invalid_dropped_events');
   roots.push({window:capture.label,allocation,vm:capture.vm,identity:[root.trace_id,root.span_id],
     dropped_events:String(dropped),timestamp_ties:chronology.exclusion_reasons.includes('ambiguous_coordinator_event_order')});
   const excluded=[...chronology.exclusion_reasons];
   if(root.attributes['quod.dtx.duration_scope']!==OWNER_SCOPE)excluded.push('unknown_coordinator_duration_scope');
   const children=[...byId.values()].filter(s=>s!==root&&descendant(s,root));
   const work=children.map(s=>{
     const b=spanBounds(s),reasons=[];
     if(!b)reasons.push('invalid_span_timestamp');
     if(s.resource['service.instance.id']!==allocation)reasons.push('cross_allocation_clock');
     if(b&&bounds&&(b[0]<bounds[0]||b[1]>bounds[1]))reasons.push('outside_attempt_bounds');
     for(const field of ['dropped_events','dropped_attributes','dropped_links']){
       const n=exactNonnegative(s[field]??0);if(n===null||n>0n)reasons.push(field);
     }
     return {identity:[s.trace_id,s.span_id],parent:s.parent,name:s.name,component:component(s),
       interval_ns:reasons.length?null:b.map(String),excluded_reasons:reasons};
   });
   timelines.push({identity:[root.trace_id,root.span_id],allocation,
     interval_ns:bounds?bounds.map(String):null,excluded_reasons:excluded,
     stages:excluded.length?[]:chronology.intervals.map(i=>({stage:i.stage,interval_ns:[String(i.lo),String(i.hi)]})),
     event_order:chronology.event_order,issues:chronology.issues,ordinary_descendants:work});
 }
 const sampler=reconcileSampler({...inventory,roots});
 const exclusions=timelines.filter(t=>t.excluded_reasons.length).map(t=>({identity:t.identity,reasons:t.excluded_reasons}));
 return {schema:'quod.c4.phase1-analysis/v1',inventory,sampler,timelines,
   excluded_coordinators:exclusions,excluded_coordinator_count:exclusions.length,
   excluded_attempts:sampler.excluded,excluded_attempt_count:sampler.excluded.length,
   configuration:captures.map(c=>({allocation:c.allocation,vm:c.vm,
     before:c.sdk_config_before??null,after:c.sdk_config_after??null})),issues,
   interpretation:[
     'Sampling bounds describe this window only; a 100% window does not retrospectively identify the old missing roots.',
     'Stage and child spans are ordinary observations, not exclusive CPU or mailbox attribution. Parallel intervals are not summed.',
     'Missing, tied, dropped and censored evidence remains explicit. No hot-path capture or shutdown inference is used.',
     'Foreign-history work is shared with L2; atomic DTX work is L3-only; generic owner/consensus spans remain unresolved.'
   ]};
}

export const independentStartKey=key;
