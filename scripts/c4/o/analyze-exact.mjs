// Offline .158 exact/current lifecycle audit. Never fetches, submits or polls.
// Usage: node analyze-exact.mjs OUTPUT.json MANIFEST_OR_FULL_TRACE.json [...]
// Means and interval unions, never quantile subtraction or cross-host clocks.
import {readFile,writeFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import {flatten,unionNs} from './owner-core.mjs';
const F='quod.foreign.',O='quod.owner.';
const ms=n=>Number(n)/1e6,mean=xs=>xs.length?xs.reduce((a,b)=>a+b,0)/xs.length:null;
const key=s=>`${s.trace_id}/${s.span_id}`, parent=s=>`${s.trace_id}/${s.parent}`;
const allocation=s=>s.resource['service.instance.id']??null;
const attr=(s,k)=>s.attributes[F+k],oa=(s,k)=>s.attributes[O+k];
const is=suffix=>s=>s.name===F+suffix;
const interval=s=>[BigInt(s.start_ns),BigInt(s.end_ns)];
const duration=s=>ms(BigInt(s.end_ns)-BigInt(s.start_ns));
const evidence=s=>({trace_id:s.trace_id,span_id:s.span_id,parent:s.parent,allocation:allocation(s),name:s.name,start_ns:s.start_ns,end_ns:s.end_ns,duration_ms:duration(s),attributes:s.attributes});
const count=(s,k)=>attr(s,k)===undefined?null:Number(attr(s,k));
export function audit(input){
  const issues=[],byId=new Map(),repeated=[];
  for(const s of input){
    const k=key(s),old=byId.get(k);
    if(old){if(JSON.stringify(old)!==JSON.stringify(s))issues.push({kind:'conflicting_duplicate_span',key:k});else repeated.push(k);}
    else byId.set(k,s);
  }
  const spans=[...byId.values()],children=new Map();
  for(const s of spans){const k=parent(s),xs=children.get(k)??[];xs.push(s);children.set(k,xs);
    if(BigInt(s.end_ns)<BigInt(s.start_ns))issues.push({kind:'negative_duration',key:key(s)});
    if(s.name.startsWith(F)&&(Number(s.dropped_attributes)||Number(s.dropped_events)||Number(s.dropped_links)))issues.push({kind:'dropped_foreign_metadata',key:key(s),attributes:s.dropped_attributes,events:s.dropped_events,links:s.dropped_links});
    if(s.name.startsWith(F)&&['unclassified','unclassified_exception'].includes(attr(s,'reason')))issues.push({kind:'unclassified_foreign_reason',key:key(s)});
  }
  function ancestor(s,predicate){const seen=new Set();let at=byId.get(parent(s));while(at&&!seen.has(key(at))){if(predicate(at))return at;seen.add(key(at));at=byId.get(parent(at));}return null;}
  function desc(s){const out=[],seen=new Set();function visit(p){for(const c of children.get(key(p))??[]){if(seen.has(key(c)))continue;seen.add(key(c));out.push(c);visit(c);}}visit(s);return out;}
  function partition(s,parts){const local=parts.filter(p=>allocation(p)!==null&&allocation(p)===allocation(s)),[lo,hi]=interval(s),total=hi-lo,covered=unionNs(local.map(interval),lo,hi);
    return{elapsed_ms:ms(total),attributed_union_ms:ms(covered),residual_ms:ms(total-covered),coverage_percent:total?100*Number(covered)/Number(total):null,cross_allocation_excluded:parts.length-local.length};}
  const producer=s=>is('verification_worker')(s)||is('probe_worker')(s);
  const producers=spans.filter(producer),producerRows=[];
  for(const p of producers){
    const stages=desc(p).filter(s=>attr(s,'stage_ordinal')!==undefined&&ancestor(s,producer)===p),ord=stages.map(s=>Number(attr(s,'stage_ordinal'))).sort((a,b)=>a-b),started=count(p,'stages_started'),completed=count(p,'stages_completed');
    const pass=started!==null&&started===completed&&started===ord.length&&ord.every((n,i)=>n===i+1);
    if(!pass)issues.push({kind:'producer_stage_count_or_sequence',key:key(p),started,completed,observed:ord});
    const pids=[...new Set(stages.map(s=>attr(s,'stage_process')))];
    if(pids.length>1||(is('verification_worker')(p)&&pids.length===1&&pids[0]!==attr(p,'worker_pid')))issues.push({kind:'stage_producer_pid_mismatch',key:key(p),pids});
    const leaves=stages.filter(s=>!desc(s).some(c=>stages.includes(c)));
    producerRows.push({...evidence(p),stage_count_pass:pass,stages_started:started,stages_completed:completed,observed_stage_count:stages.length,stage_processes:pids,
      stage_union:partition(p,stages),deepest_stage_union:partition(p,leaves),
      stages:stages.map(s=>({...evidence(s),direct_child_partition:partition(s,(children.get(key(s))??[]).filter(c=>c.name.startsWith(F)))}))});
  }
  const collections=spans.filter(is('probe_collection')).map(p=>{
    const probes=(children.get(key(p))??[]).filter(is('probe_worker')),expected=count(p,'expected_probe_children'),ord=probes.map(s=>Number(attr(s,'probe_ordinal'))).sort((a,b)=>a-b);
    const pass=expected!==null&&ord.length===expected&&ord.every((n,i)=>n===i+1);
    if(!pass)issues.push({kind:'probe_export_count_or_sequence',key:key(p),expected,observed_ordinals:ord,note:'A cancelled/killed probe may never export; keep partial detail, not zero work.'});
    return{...evidence(p),expected,observed:probes.length,ordinals:ord,count_pass:pass,child_union:partition(p,probes)};
  });
  const workers=spans.filter(is('verification_worker'));
  for(const w of workers){const cs=collections.filter(c=>ancestor(byId.get(`${c.trace_id}/${c.span_id}`),is('verification_worker'))===w),expected=cs.reduce((n,c)=>n+(c.expected??0),0);
    if(count(w,'probe_children_started')===null||expected!==count(w,'probe_children_started'))issues.push({kind:'worker_probe_collection_count',key:key(w),expected_from_collections:expected,worker_started:count(w,'probe_children_started')});
  }
  const residences=spans.filter(is('caller_residence')).map(r=>{
    const stages=(children.get(key(r))??[]).filter(is('owner_stage')),expected=Number(oa(r,'stages_expected')),ord=stages.map(s=>Number(oa(s,'stage_ordinal'))).sort((a,b)=>a-b);
    const pass=Number.isSafeInteger(expected)&&expected===ord.length&&ord.every((n,i)=>n===i+1)&&typeof oa(r,'terminal')==='string';
    if(!pass)issues.push({kind:'caller_stage_count_or_terminal',key:key(r),expected:Number.isFinite(expected)?expected:null,observed_ordinals:ord});
    return{...evidence(r),count_pass:pass,terminal:oa(r,'terminal')??null,mailbox_native:oa(r,'mailbox_native')??null,stage_union:partition(r,stages),stages:stages.map(evidence)};
  });
  const pageRows=[],admissions=spans.filter(is('page_admission')),terminals=spans.filter(is('page_completion_owner'));
  const pageKey=s=>JSON.stringify([allocation(s),s.trace_id,s.parent,attr(s,'page_id')]);
  const pageKeys=new Set([...admissions,...terminals].map(pageKey));
  for(const k of pageKeys){const aa=admissions.filter(s=>pageKey(s)===k),tt=terminals.filter(s=>pageKey(s)===k),p=byId.get(parent(aa[0]??tt[0]));
    const expected=aa.reduce((n,s)=>n+(count(s,'page_expected_terminal')??0),0),observed=tt.reduce((n,s)=>n+(count(s,'page_terminal_count')??0),0);
    const pass=aa.length===1&&tt.length===1&&expected===1&&observed===1&&p?.name===F+'page_fetch'&&typeof attr(tt[0],'page_terminal')==='string';
    if(!pass)issues.push({kind:'page_admission_terminal_count',key:k,admissions:aa.length,terminals:tt.length,expected,observed,parent_present:!!p});
    pageRows.push({key:JSON.parse(k),count_pass:pass,expected,observed,page:p?evidence(p):null,admissions:aa.map(evidence),terminals:tt.map(evidence),
      terminal_started_after_parent_end:p&&tt.length===1?BigInt(tt[0].start_ns)>BigInt(p.end_ns):null});
  }
  // A successfully returned real page necessarily crossed actual page admission.
  // Failed calls may expire before admission; absence alone cannot invent a pull.
  for(const p of spans.filter(is('page_fetch'))){const cc=children.get(key(p))??[],real=cc.some(is('page_wait')),aa=cc.filter(is('page_admission'));
    if(real&&attr(p,'page_entries')!==undefined&&aa.length!==1)issues.push({kind:'successful_real_page_missing_admission',key:key(p),admissions:aa.length});
  }
  const jobKey=s=>JSON.stringify([allocation(s),s.attributes['quod.namespace']??null,s.attributes['quod.genesis_anchor']??null,attr(s,'job_id')??null]);
  const jobs=new Map();
  for(const w of workers){const k=jobKey(w),xs=jobs.get(k)??[];xs.push(w);jobs.set(k,xs);if(!attr(w,'job_id')||!Number.isSafeInteger(Number(attr(w,'attempt'))))issues.push({kind:'worker_job_identity_missing',key:key(w)});}
  const installations=spans.filter(is('result_install')).map(s=>{
    const w=ancestor(s,is('verification_worker'));
    if(!w)issues.push({kind:'result_install_missing_worker',key:key(s)});
    return{...evidence(s),worker_key:w?key(w):null,started_after_worker_end:w&&allocation(w)===allocation(s)?BigInt(s.start_ns)>BigInt(w.end_ns):null};
  });
  for(const w of workers){const handoffs=desc(w).filter(is('worker_handoff')),installed=installations.filter(s=>s.worker_key===key(w));
    if(handoffs.length===1&&installed.length!==1)issues.push({kind:'worker_handoff_install_count',key:key(w),handoffs:1,installations:installed.length,note:'Late export or owner death may explain absence; retain incomplete terminal coverage.'});
  }
  const calls=spans.filter(is('owner_request')),associations=new Map(calls.map(c=>[key(c),new Set()]));
  function callerAt(s){return s&&(is('owner_request')(s)?s:ancestor(s,is('owner_request')));}
  function associate(c,w){if(c)associations.get(key(c))?.add(key(w));}
  for(const w of workers){associate(callerAt(byId.get(parent(w))),w);for(const l of w.links)associate(callerAt(byId.get(`${l.trace_id}/${l.span_id}`)),w);}
  const joins=spans.filter(is('join')).map(j=>{
    const linked=j.links.map(l=>byId.get(`${l.trace_id}/${l.span_id}`)).filter(s=>s&&is('verification_worker')(s));
    const matching=workers.filter(w=>allocation(w)===allocation(j)&&attr(w,'job_id')===attr(j,'job_id')&&String(attr(w,'attempt'))===String(attr(j,'attempt')));
    const matches=[...new Set([...linked,...matching])];for(const w of matches)associate(callerAt(j),w);
    if(matches.length!==1)issues.push({kind:'join_worker_unresolved_or_duplicate',key:key(j),matches:matches.map(key)});
    return{...evidence(j),worker_keys:matches.map(key),worker_link_present:linked.length>0,job_identity_only_correlation:linked.length===0&&matching.length===1};
  });
  const callerRows=calls.map(c=>{
    const rs=(children.get(key(c))??[]).filter(is('caller_residence')),ownerStages=rs.flatMap(r=>(children.get(key(r))??[]).filter(is('owner_stage')));
    const ww=[...associations.get(key(c))].map(k=>byId.get(k)),parts=ww.flatMap(w=>desc(w).filter(s=>attr(s,'stage_ordinal')!==undefined));
    const expired=attr(c,'cause')==='caller_expired',local=ww.filter(w=>allocation(w)===allocation(c));
    return{...evidence(c),cause:attr(c,'cause')??null,residence_keys:rs.map(key),worker_keys:ww.map(key),owner_stage_partition:partition(c,ownerStages),shared_worker_stage_overlap:partition(c,parts),
      combined_observed_union:partition(c,[...ownerStages,...parts]),expired_with_observed_worker_outliving_call:expired&&local.some(w=>BigInt(w.end_ns)>BigInt(c.end_ns)),
      note:'Owner running-stage residence is observed waiting, not exclusive computation. Worker total counts once per job; no cross-allocation subtraction.'};
  });
  const jobRows=[...jobs].map(([k,ws])=>{
    ws.sort((a,b)=>Number(attr(a,'attempt'))-Number(attr(b,'attempt')));
    const attempts=ws.map(w=>Number(attr(w,'attempt'))),duplicate=attempts.length!==new Set(attempts).size;
    if(duplicate)issues.push({kind:'multiple_workers_same_job_attempt',key:k,attempts});
    const lo=ws.reduce((n,w)=>BigInt(w.start_ns)<n?BigInt(w.start_ns):n,BigInt(ws[0].start_ns)),hi=ws.reduce((n,w)=>BigInt(w.end_ns)>n?BigInt(w.end_ns):n,BigInt(ws[0].end_ns)),united=unionNs(ws.map(interval),lo,hi);
    return{key:JSON.parse(k),attempts,worker_keys:ws.map(key),worker_elapsed_sum_ms:ws.reduce((n,w)=>n+duration(w),0),
      worker_elapsed_union_ms:ms(united),between_observed_attempts_ms:ms(hi-lo-united),
      same_job_attempt_gaps:attempts.slice(1).filter((n,i)=>n!==attempts[i]+1),
      note:'Missing earlier/later sampled attempts remain possible; a new job_id is a new job, never labelled rearmed from slot equality alone.'};
  });
  const unresolvedLinks=[],edges=[];
  for(const s of spans)for(const l of s.links){const found=byId.has(`${l.trace_id}/${l.span_id}`),e={from:key(s),to:`${l.trace_id}/${l.span_id}`,source_name:s.name,resolved:found};edges.push(e);if(!found)unresolvedLinks.push(e);}
  const rows=producerRows.filter(is('verification_worker')),elapsed=rows.reduce((n,r)=>n+r.duration_ms,0),covered=rows.reduce((n,r)=>n+r.stage_union.attributed_union_ms,0);
  return{grammar:'quod exact-reference 0.7.160',unique_spans:spans.length,deduplicated_copies:repeated.length,issues,workers:rows,probe_workers:producerRows.filter(is('probe_worker')),probe_collections:collections,
    callers:callerRows,residences,pages:pageRows,joins,jobs:jobRows,installations,link_edges:edges,unresolved_links:unresolvedLinks,unresolved_trace_ids:[...new Set(unresolvedLinks.map(l=>l.to.split('/')[0]))],
    summary:{workers:rows.length,exact_workers:rows.filter(w=>attr(w,'work')==='request_exact').length,callers:callerRows.length,jobs:jobRows.length,pages:pageRows.length,
      worker_mean_ms:mean(rows.map(w=>w.duration_ms)),worker_stage_union_mean_ms:mean(rows.map(w=>w.stage_union.attributed_union_ms)),worker_residual_mean_ms:mean(rows.map(w=>w.stage_union.residual_ms)),worker_deepest_stage_residual_mean_ms:mean(rows.map(w=>w.deepest_stage_union.residual_ms)),
      worker_stage_sum_coverage_percent:elapsed?100*covered/elapsed:null,caller_wait_mean_ms:mean(callerRows.map(c=>c.duration_ms)),caller_owner_stage_residual_mean_ms:mean(callerRows.map(c=>c.owner_stage_partition.residual_ms)),
      caller_expired_with_worker_outliving:callerRows.filter(c=>c.expired_with_observed_worker_outliving_call).length,structural_count_pass:rows.length>0&&issues.length===0,
      causal_completeness_claim_permitted:false},
    limits:['Observed counts do not establish collection-window, reverse-link, sampling or exporter completeness. Require separate boundary/export controls.',
      'Unfinished or killed producer spans can be absent entirely; expected probe/page markers expose some, not every missing parent.',
      'Native mailbox duration is retained raw; convert only from captured VM native-unit metadata. SDK Unix timestamps are only compared within one allocation; verify no clock warp/incarnation change before attribution claims.',
      'Page terminal and result-install children may outlive ended parents. Do not reject causal parenting or add outside-parent time to parent duration.',
      'resident_start_height, disk_start_height, disk_replayed_entries, network_advance_verified_entries, local_advance_verified_entries and hint_verified_entries are separate. Final minus resident is not network traffic.',
      'network_advance_verified_entries excludes tip/probe traffic; use page_entries/page_source for observed returned pages, not transport bytes.',
      'Stage union is observed local wall time, not CPU/exclusive attribution. Deepest-stage residual retains aggregate-wrapper gaps; page/probe parallel children are interval-unioned.',
      'Same-job worker survival after caller expiry is proven only for linked/identity-correlated observed worker end; no missing worker is labelled stopped or permanently parked.']};
}
async function main(){
  const [out,...inputs]=process.argv.slice(2);assert(out&&inputs.length,'OUTPUT.json MANIFEST_OR_FULL_TRACE.json [...] required');assert(resolve(out).startsWith('/tmp/'),'Scratch output only');
  const all=[],archives=[],errors=[],seenPaths=new Set();
  async function load(path,traceId){path=resolve(path);if(seenPaths.has(path))return;seenPaths.add(path);let body,doc;try{body=await readFile(path);doc=JSON.parse(body);}catch(e){errors.push({path,error:e.message});return;}
    if(doc.batches||doc.resourceSpans||doc.trace?.batches||doc.trace?.resourceSpans){try{const ss=flatten(doc,traceId);all.push(...ss);archives.push({path,bytes:body.length,sha256:createHash('sha256').update(body).digest('hex'),spans:ss.length});}catch(e){errors.push({path,error:e.message});}return;}
    const rows=Array.isArray(doc)?doc:doc.traces;
    if(!Array.isArray(rows)){errors.push({path,error:'not a full trace or trace manifest'});return;}
    for(const row of rows){if(row.error||row.retrieval_error||!row.path){errors.push({path,trace_id:row.trace_id,error:row.error??row.retrieval_error??'missing trace path'});continue;}await load(resolve(dirname(path),row.path),row.trace_id);}
  }
  for(const path of inputs)await load(path);
  const report={generated_at:new Date().toISOString(),inputs,archives,retrieval_errors:errors,...audit(all)};
  if(errors.length)report.summary.structural_count_pass=false;
  await writeFile(out,JSON.stringify(report,null,2)+'\n',{flag:'wx'});
  console.log(JSON.stringify({output:out,...report.summary,retrieval_errors:errors.length,issues:report.issues.length,unresolved_links:report.unresolved_links.length},null,2));
  if(!report.summary.structural_count_pass)process.exitCode=1;
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url))await main();
