// Offline-safe primitives shared by the independent-owner capture and analyzer.
import assert from 'node:assert/strict';
export const ROOT='quod.consensus.owner_turn', STEP='quod.consensus.owner_step';
export const value=v=>v?.stringValue??v?.intValue??v?.doubleValue??v?.boolValue??null;
export const attrs=xs=>Object.fromEntries((xs??[]).map(x=>[x.key,value(x.value)]));
export function searchHex(id,bytes){assert(typeof id==='string'&&new RegExp(`^[a-f0-9]{1,${bytes*2}}$`,'i').test(id),'Invalid Tempo search hex identifier');return id.toLowerCase().padStart(bytes*2,'0');}
export function hex(id,bytes){
  if(!id)return null;
  if(new RegExp(`^[a-f0-9]{${bytes*2}}$`,'i').test(id))return id.toLowerCase();
  const decoded=Buffer.from(id,'base64');assert.equal(decoded.length,bytes,'Invalid trace/span identifier');return decoded.toString('hex');
}
export function flatten(doc,traceId){
  const batches=doc.batches??doc.resourceSpans??doc.trace?.resourceSpans??doc.trace?.batches;
  assert(Array.isArray(batches),'Missing full trace batches');
  return batches.flatMap(b=>(b.scopeSpans??b.instrumentationLibrarySpans??[]).flatMap(sc=>(sc.spans??[]).map(s=>({
    trace_id:hex(s.traceId??traceId,16),span_id:hex(s.spanId,8),parent:hex(s.parentSpanId,8),
    name:s.name,start_ns:String(s.startTimeUnixNano),end_ns:String(s.endTimeUnixNano),
    attributes:attrs(s.attributes),resource:attrs(b.resource?.attributes),
    links:(s.links??[]).map(l=>({trace_id:hex(l.traceId,16),span_id:hex(l.spanId,8),attributes:attrs(l.attributes)})),
    events:(s.events??[]).map(e=>({name:e.name,time_ns:String(e.timeUnixNano),attributes:attrs(e.attributes)})),
    dropped_attributes:s.droppedAttributesCount??0,dropped_events:s.droppedEventsCount??0,dropped_links:s.droppedLinksCount??0
  }))));
}
export function unionNs(intervals,lo,hi){
  const xs=intervals.map(([a,b])=>[BigInt(a),BigInt(b)]).map(([a,b])=>[a<lo?lo:a,b>hi?hi:b]).filter(([a,b])=>b>a).sort((a,b)=>a[0]<b[0]?-1:a[0]>b[0]?1:0);
  let total=0n,end=lo;
  for(const[a,b]of xs){const begin=a>end?a:end;if(b>begin)total+=b-begin;if(b>end)end=b;}
  return total;
}
export function inspectTrace(spans){
  const issues=[],byId=new Map();
  for(const s of spans){if(byId.has(s.span_id))issues.push(`duplicate_span:${s.span_id}`);byId.set(s.span_id,s);if(BigInt(s.end_ns)<BigInt(s.start_ns))issues.push(`negative_span:${s.span_id}`);}
  const roots=spans.filter(s=>s.name===ROOT);
  if(roots.length!==1)issues.push(`owner_root_count:${roots.length}`);
  const root=roots[0];
  if(root?.parent&&!/^0+$/.test(root.parent))issues.push('owner_root_has_parent');
  for(const s of spans){
    if(s.name!==ROOT&&s.name!==STEP)issues.push(`unexpected_span:${s.name}`);
    if(s.name!==STEP)continue;
    const visited=new Set([s.span_id]);let at=s;
    while(at!==root){
      const p=byId.get(at.parent);
      if(!p){issues.push(`orphan_child:${s.span_id}:${at.parent}`);break;}
      if(visited.has(p.span_id)){issues.push(`parent_cycle:${s.span_id}`);break;}
      if(BigInt(at.start_ns)<BigInt(p.start_ns)||BigInt(at.end_ns)>BigInt(p.end_ns))issues.push(`child_outside_parent:${at.span_id}`);
      if(p.resource['service.instance.id']!==s.resource['service.instance.id'])issues.push(`cross_resource_child:${s.span_id}`);
      visited.add(p.span_id);at=p;
    }
  }
  return {root,issues,spans:spans.length,children:spans.filter(s=>s.name===STEP).length,
    child_export_completeness:'unproven: no expected-child count; orphan-free trees and stable snapshots cannot detect an entirely missing leaf'};
}
export function sequenceAudit(turns){
  const groups=new Map();
  for(const t of turns){const a=t.attributes,k=JSON.stringify([t.resource['service.instance.id'],a['quod.namespace'],a['quod.owner.incarnation'],a['quod.owner.pid']]);
    const xs=groups.get(k)??[];xs.push(t);groups.set(k,xs);}
  return [...groups].map(([key,xs])=>{xs.sort((a,b)=>BigInt(a.attributes['quod.owner.sequence'])<BigInt(b.attributes['quod.owner.sequence'])?-1:1);const gaps=[],duplicates=[],overlaps=[];
    for(let i=1;i<xs.length;i++){const prev=BigInt(xs[i-1].attributes['quod.owner.sequence']),next=BigInt(xs[i].attributes['quod.owner.sequence']);
      if(next===prev)duplicates.push(String(next));else if(next!==prev+1n)gaps.push({after:String(prev),before:String(next),missing:String(next-prev-1n)});
      if(BigInt(xs[i].attributes['quod.owner.start_monotonic_ns'])<BigInt(xs[i-1].attributes['quod.owner.end_monotonic_ns']))overlaps.push({after:String(prev),before:String(next)});}
    return{key:JSON.parse(key),count:xs.length,first_sequence:xs[0].attributes['quod.owner.sequence'],last_sequence:xs.at(-1).attributes['quod.owner.sequence'],gaps,duplicates,overlaps,turns:xs};});
}
