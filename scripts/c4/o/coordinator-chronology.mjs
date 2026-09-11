// O-only views. Wire order is evidence, not causality; never mutate inputs.
import assert from 'node:assert/strict';
import {flatten} from './owner-core.mjs';
import {LEGACY_SCOPE} from './coordinator-inventory.mjs';

export function exactNonnegative(value) {
  if(typeof value==='number')return Number.isSafeInteger(value)&&value>=0?BigInt(value):null;
  if(typeof value==='string'&&/^[0-9]+$/.test(value))return BigInt(value);
  return null;
}
export function spanBounds(span) {
  const lo=exactNonnegative(span.start_ns),hi=exactNonnegative(span.end_ns);
  return lo!==null&&hi!==null&&hi>=lo?[lo,hi]:null;
}

// The shared flattener converts times with String(...). Preserve raw types in
// our independent view so precision already lost in JSON Number is refused.
export function flattenO(doc,traceId) {
  const batches=doc.batches??doc.resourceSpans??doc.trace?.resourceSpans??doc.trace?.batches;
  const flat=flatten(doc,traceId);
  const raw=batches.flatMap(b=>(b.scopeSpans??b.instrumentationLibrarySpans??[])
    .flatMap(sc=>sc.spans??[]));
  assert.equal(flat.length,raw.length);
  return flat.map((s,i)=>({...s,start_ns:raw[i].startTimeUnixNano,end_ns:raw[i].endTimeUnixNano,
    events:s.events.map((e,j)=>({...e,time_ns:raw[i].events[j].timeUnixNano}))}));
}

const stages=new Set(['begin','prepare_wave','decision','finalize_wave','applied_wave','complete']);
const relevant=new Set(['dtx.stage','dtx.completed','dtx.done_observed','dtx.worker_error',
  'dtx.coordinator.close_observed','dtx.coordinator_closed']);

export function coordinatorChronology(span,scope) {
  const key=`${span.trace_id}/${span.span_id}`,issues=[],reasons=new Set(),bounds=spanBounds(span);
  const fail=(kind,extra={})=>{issues.push({kind,key,...extra});reasons.add(kind);};
  if(!bounds)fail('invalid_coordinator_span_timestamp');
  for(const field of ['dropped_events','dropped_attributes','dropped_links']) {
    const count=exactNonnegative(span[field]===undefined?0:span[field]);
    if(count===null)fail('invalid_coordinator_drop_count',{field});
    else if(count>0n)fail(field==='dropped_events'?'coordinator_dropped_events':'coordinator_dropped_metadata',
      {field,count:String(count)});
  }
  const all=span.events.map((event,wire_index)=>({event,wire_index})).filter(x=>relevant.has(x.event.name));
  const endpoint=e=>e.name==='dtx.stage'||(scope===LEGACY_SCOPE&&e.name==='dtx.completed');
  const timed=[];
  for(const {event:e,wire_index} of all) {
    const at=exactNonnegative(e.time_ns);
    if(at===null)fail('invalid_coordinator_event_timestamp',{wire_index,event:e.name});
    else {
      if(bounds&&(at<bounds[0]||at>bounds[1]))fail('coordinator_event_outside_span',{wire_index,event:e.name,time_ns:String(at)});
      timed.push({event:e,wire_index,at});
    }
    if(e.name==='dtx.stage'&&!stages.has(e.attributes['quod.dtx.stage']))
      fail('unknown_group_stage',{wire_index,stage:e.attributes['quod.dtx.stage']??null});
  }
  // Stable wire index is only diagnostic order for a tied bucket; that bucket
  // invalidates phase attribution instead of creating a causal tie-break.
  timed.sort((x,y)=>x.at<y.at?-1:x.at>y.at?1:x.wire_index-y.wire_index);
  for(let i=0;i<timed.length;) {
    let j=i+1;while(j<timed.length&&timed[j].at===timed[i].at)j++;
    const tied=timed.slice(i,j);
    if(j-i>1&&tied.some(x=>endpoint(x.event)))fail('ambiguous_coordinator_event_order',
      {time_ns:String(timed[i].at),wire_indices:tied.map(x=>x.wire_index)});
    i=j;
  }
  const events=timed.filter(x=>endpoint(x.event)),intervals=[];
  for(let i=0;i<events.length;i++) {
    const {event:e,wire_index,at}=events[i];
    if(e.name!=='dtx.stage')continue;
    const next=events[i+1],stage=e.attributes['quod.dtx.stage'];
    if(!next)issues.push({kind:'unterminated_group_stage',key,stage,wire_index});
    else if(!reasons.size)intervals.push({stage:`dtx.${stage}`,lo:at,hi:next.at});
  }
  return {issues,exclusion_reasons:[...reasons],intervals:reasons.size?[]:intervals,
    event_order:timed.map(x=>({wire_index:x.wire_index,name:x.event.name,time_ns:String(x.at)})),
    endpoint_semantics:scope===LEGACY_SCOPE?'legacy_completed_endpoint':'stage_to_stage_only'};
}
