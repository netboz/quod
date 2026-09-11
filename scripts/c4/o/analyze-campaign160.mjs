// Offline .160 attribution. No network, resubmission, or expected-auditor edits.
// node analyze-campaign160.mjs OUTPUT.json RUN/all-results.json MANIFEST [...]
import {readFile,writeFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
import {flatten} from './owner-core.mjs';
const key=s=>`${s.trace_id}/${s.span_id}`,pk=s=>`${s.trace_id}/${s.parent}`;
const alloc=s=>s.resource['service.instance.id'];
const ns=s=>[BigInt(s.start_ns),BigInt(s.end_ns)];
const ms=n=>Number(n)/1e6;
const duration=s=>ms(BigInt(s.end_ns)-BigInt(s.start_ns));
const a=(s,k)=>s.attributes[k];
const F='quod.foreign.',O='quod.owner.';
const clientStages=new Set(['json_decode','session_admission','decode_and_bind',
  'gateway_signature_verify','local_target_lookup','goal_decode','goal_materialize',
  'response_encode','request_decode','request_crypto_verify']);
// Enclosing HTTP/public-proof/coordinate waits are NOT evidence of the work
// occupying them. In particular outside-prove time is never credited by default.
const groupStages=new Set(['begin','prepare_wave','decision','finalize_wave',
  'applied_wave','complete']);
const evidence=s=>({key:key(s),name:s.name,allocation:alloc(s)??null,
  start_ns:s.start_ns,end_ns:s.end_ns,duration_ms:duration(s),attributes:s.attributes,links:s.links});

export function partition(lo,hi,segments){
  const cuts=new Set([lo,hi]);
  const ss=segments.map(s=>({...s,lo:s.lo<lo?lo:s.lo,hi:s.hi>hi?hi:s.hi}))
    .filter(s=>s.hi>s.lo);
  for(const s of ss){cuts.add(s.lo);cuts.add(s.hi);}
  const points=[...cuts].sort((x,y)=>x<y?-1:x>y?1:0),out={};
  for(let i=1;i<points.length;i++){
    const left=points[i-1],right=points[i];
    const names=[...new Set(ss.filter(s=>s.lo<=left&&s.hi>=right).map(s=>s.stage))].sort();
    // Parallel work stays an explicit union bucket, never credited twice or
    // arbitrarily awarded to one owner. This measures occupancy, not CPU.
    const bucket=names.length===0?'unknown':names.length===1?names[0]:`overlap:${names.join('+')}`;
    out[bucket]=(out[bucket]??0)+ms(right-left);
  }
  return out;
}

export function analyze(input,results){
  const issues=[],byId=new Map();
  for(const s of input){const old=byId.get(key(s));
    if(old&&JSON.stringify(old)!==JSON.stringify(s))issues.push({kind:'conflicting_span_copy',key:key(s)});
    else if(!old)byId.set(key(s),s);
  }
  const spans=[...byId.values()];
  for(const s of spans)if(BigInt(s.end_ns)<BigInt(s.start_ns))issues.push({kind:'negative_duration',key:key(s)});
  function below(s,ancestor){const seen=new Set();while(s&&!seen.has(key(s))){
    if(key(s)===key(ancestor))return true;seen.add(key(s));s=byId.get(pk(s));}return false;}
  function linkedToTree(s,root){return s.links.some(l=>{const p=byId.get(`${l.trace_id}/${l.span_id}`);return p&&below(p,root);});}
  const coordinates=spans.filter(s=>s.name==='quod.dtx.coordinate').map(s=>{
    const stages=[],events=s.events.filter(e=>e.name==='dtx.stage'||e.name==='dtx.completed');
    for(let i=0;i<events.length;i++){
      const e=events[i],stage=e.attributes['quod.dtx.stage'];
      if(e.name!=='dtx.stage')continue;
      const next=events[i+1];
      if(!groupStages.has(stage))issues.push({kind:'unknown_group_stage',key:key(s),stage});
      if(!next){issues.push({kind:'unterminated_group_stage',key:key(s),stage});continue;}
      const lo=BigInt(e.time_ns),hi=BigInt(next.time_ns),[start,end]=ns(s);
      if(lo<start||hi>end||hi<lo){issues.push({kind:'invalid_group_stage_interval',key:key(s),stage});continue;}
      stages.push({stage:`dtx.${stage}`,lo,hi});
    }
    if(!events.some(e=>e.name==='dtx.completed'))issues.push({kind:'missing_group_completion_event',key:key(s)});
    if(Number(s.dropped_events)||Number(s.dropped_attributes))issues.push({kind:'dropped_group_metadata',key:key(s)});
    return{span:s,stages};
  });
  const queue=spans.filter(s=>s.name===F+'caller_residence').map(r=>{
    const markers=spans.filter(s=>pk(s)===key(r)&&s.name===F+'queue_blocker');
    const expected=Number(a(r,O+'blockers_expected'));
    const ordinals=markers.map(s=>Number(a(s,O+'blocker_ordinal'))).sort((x,y)=>x-y);
    const pass=Number.isSafeInteger(expected)&&expected===ordinals.length&&ordinals.every((x,i)=>x===i+1);
    if(!pass)issues.push({kind:'queue_blocker_count_or_sequence',key:key(r),expected:Number.isFinite(expected)?expected:null,ordinals});
    const budgets=spans.filter(s=>pk(s)===key(r)&&s.name===F+'owner_stage').map(s=>{
      const kind=a(s,'quod.caller.budget_kind'),remaining=a(s,'quod.caller.remaining_ms');
      if((kind==='infinity'&&remaining!==undefined)||(kind==='finite'&&(!Number.isFinite(Number(remaining))||Number(remaining)<0))||!['finite','infinity'].includes(kind))
        issues.push({kind:'invalid_budget_observation',key:key(s),budget_kind:kind??null,remaining_ms:remaining??null});
      return{...evidence(s),budget_kind:kind??null,remaining_ms:remaining??null,
        work_lifetime:a(s,F+'work_lifetime')??null,work_remaining_ms:a(s,F+'work_remaining_ms')??null};
    });
    const queueStages=spans.filter(s=>pk(s)===key(r)&&s.name===F+'owner_stage'&&
      ['queued','parked','custody_wait'].includes(a(s,O+'stage'))).map(s=>{
      const[lo,hi]=ns(s),mm=markers.filter(m=>alloc(m)===alloc(s)&&BigInt(m.start_ns)>=lo&&BigInt(m.start_ns)<=hi)
        .sort((x,y)=>BigInt(x.start_ns)<BigInt(y.start_ns)?-1:BigInt(x.start_ns)>BigInt(y.start_ns)?1:0);
      const segments=mm.map((m,i)=>({lo:BigInt(m.start_ns),hi:mm[i+1]?BigInt(mm[i+1].start_ns):hi,
        stage:JSON.stringify([a(m,O+'blocker'),a(m,O+'blocker_job_id')??null,a(m,O+'blocker_attempt')??null])}));
      return{stage:evidence(s),blocker_union_ms:partition(lo,hi,segments),
        note:'Marker-to-next-marker intervals bounded by this owner stage only; before-first-marker time remains unknown.'};
    });
    return{residence:evidence(r),expected:Number.isFinite(expected)?expected:null,count_pass:pass,budgets,queue_stages:queueStages,
      blockers:markers.map(s=>{
        const available=a(s,O+'blocker_trace_available')===true;
        if(available&&s.links.length===0)issues.push({kind:'advertised_predecessor_link_missing',key:key(s)});
        const links=s.links.map(l=>({trace_id:l.trace_id,span_id:l.span_id,resolved:byId.has(`${l.trace_id}/${l.span_id}`)}));
        return{...evidence(s),blocker:a(s,O+'blocker'),job_id:a(s,O+'blocker_job_id')??null,
          attempt:a(s,O+'blocker_attempt')??null,recorded:available,links,
          predecessor_unknown:!available||links.some(l=>!l.resolved)};
      })};
  });
  const roots=spans.filter(s=>s.name==='quod.client.request'),requests=[];
  const unique=new Set();
  for(const row of results){
    assert(Number.isFinite(row.latency_ms)&&row.latency_ms>=0,'Invalid observed request latency');
    if(unique.has(row.trace_id))issues.push({kind:'duplicate_request_trace',trace_id:row.trace_id});unique.add(row.trace_id);
    const rr=roots.filter(s=>s.trace_id===row.trace_id);
    const report={request_id:row.request_id,trace_id:row.trace_id,category:row.category,
      observed_ms:row.latency_ms,root_count:rr.length};
    if(rr.length!==1||!alloc(rr[0])){
      issues.push({kind:'missing_or_ambiguous_client_root',trace_id:row.trace_id,count:rr.length});
      requests.push({...report,root_ms:null,attributed_ms:0,residual_ms:row.latency_ms,
        buckets_ms:{missing_client_trace:row.latency_ms}});continue;
    }
    const root=rr[0],[lo,hi]=ns(root),segments=[];
    const related=spans.filter(s=>below(s,root));
    for(const s of related.filter(s=>alloc(s)===alloc(root))){
      const [start,end]=ns(s);
      if(s.name==='quod.prolog.prove')segments.push({lo:start,hi:end,stage:'proof_owner'});
      else if(s.name.startsWith('quod.client.')&&clientStages.has(s.name.slice(12)))
        segments.push({lo:start,hi:end,stage:'client_preparation_reply'});
    }
    const groups=coordinates.filter(c=>below(c.span,root)||linkedToTree(c.span,root));
    for(const c of groups)if(alloc(c.span)===alloc(root))segments.push(...c.stages);
    const buckets=partition(lo,hi,segments),rootMs=ms(hi-lo);
    const attributed=rootMs-(buckets.unknown??0),outside=row.latency_ms-rootMs;
    // Subtraction is of independently measured durations, not host timestamps.
    // A negative difference prevents a gate claim; do not silently clamp it away.
    if(outside<0)issues.push({kind:'client_root_exceeds_driver_duration',trace_id:row.trace_id,difference_ms:outside});
    const safeAttributed=Math.min(row.latency_ms,Math.max(0,attributed));
    requests.push({...report,root_ms:rootMs,root_allocation:alloc(root),
      attributed_ms:safeAttributed,residual_ms:row.latency_ms-safeAttributed,
      driver_minus_client_root_ms:outside,buckets_ms:{...buckets,client_boundary_unknown:outside},
      group_keys:groups.map(c=>key(c.span)),remote_groups_excluded:groups.filter(c=>alloc(c.span)!==alloc(root)).map(c=>key(c.span)),
      dropped_metadata:related.reduce((n,s)=>n+Number(s.dropped_attributes)+Number(s.dropped_events)+Number(s.dropped_links),0)});
  }
  const workers=spans.filter(s=>s.name===F+'verification_worker');
  const replayStages=spans.filter(s=>s.name===F+'cache_replay');
  const sum=field=>requests.reduce((n,r)=>n+r[field],0),total=sum('observed_ms'),attributed=sum('attributed_ms');
  const means={};for(const r of requests)for(const[k,v]of Object.entries(r.buckets_ms))means[k]=(means[k]??0)+v/requests.length;
  const unresolved=[...new Set(queue.flatMap(q=>q.blockers.flatMap(b=>b.links.filter(l=>!l.resolved).map(l=>l.trace_id))))];
  return{requests,issues,queue,groups:coordinates.map(c=>({...evidence(c.span),stages:c.stages.map(s=>({stage:s.stage,duration_ms:ms(s.hi-s.lo)}))})),
    replay:{observed_workers:workers.length,replay_stage_count:replayStages.length,
      replay_elapsed_sum_ms:replayStages.reduce((n,s)=>n+duration(s),0),
      replayed_entries:workers.reduce((n,s)=>n+Number(a(s,F+'disk_replayed_entries')??0),0),
      cold_opens:workers.reduce((n,s)=>n+Number(a(s,F+'cold_opens')??0),0),
      resume_failures:workers.reduce((n,s)=>n+Number(a(s,F+'resume_failures')??0),0),
      rows:workers.map(s=>({...evidence(s),resident_start_height:a(s,F+'resident_start_height')??null,
        disk_start_height:a(s,F+'disk_start_height')??null,final_verified_height:a(s,F+'final_verified_height')??null,
        replayed_entries:a(s,F+'disk_replayed_entries')??null,
        cold_opens:a(s,F+'cold_opens')??null,resume_failures:a(s,F+'resume_failures')??null,
        network_verified_entries:a(s,F+'network_advance_verified_entries')??null,
        local_verified_entries:a(s,F+'local_advance_verified_entries')??null,
        hint_verified_entries:a(s,F+'hint_verified_entries')??null}))},
    summary:{attempts:requests.length,captured_roots:requests.filter(r=>r.root_ms!==null).length,
      observed_mean_ms:requests.length?total/requests.length:null,
      attributed_mean_ms:requests.length?attributed/requests.length:null,
      residual_mean_ms:requests.length?(total-attributed)/requests.length:null,
      attributed_percent:total?100*attributed/total:null,bucket_means_ms:means,
      numerical_95_percent:total>0&&attributed/total>=.95,
      full_gate_claim_permitted:false},
    unresolved_predecessor_trace_ids:unresolved,
    limits:['Owner attribution only: proof_owner and DTX phase intervals identify owners, not exclusive CPU/functions.',
      'A numeric 95% is insufficient: require unchanged analyze-exact expected counts, export/drop controls, all request roots and same-allocation clock stability.',
      'Missing requests remain full residual, including failures. Purposeful trace samples cannot prove a campaign gate.',
      'No cross-host timestamp subtraction; remote workers are separate diagnostic breakdowns of local waits.',
      'Queue blocker spans are transition markers, not queue duration. Existing owner_stage is the duration owner; age_kind is not job-start age.',
      'Replays/workers are deduplicated by trace/span. Shared worker sums are not per-client latency; replay absence in a partial trace set proves nothing fleet-wide.',
      'Unfetched or unrecorded predecessors remain unknown. No automatic link traversal or reverse-link completeness claim.',
      'A later durable Complete does not change an original pending classification or its observed time-to-pending.']};
}

async function main(){
  const[out,resultPath,...inputs]=process.argv.slice(2);assert(out&&resultPath&&inputs.length,'OUTPUT RESULTS MANIFEST [...]');
  assert(resolve(out).startsWith('/tmp/'),'Scratch output only');
  const all=[],seen=new Set(),retrievalErrors=[];
  async function load(path,id){path=resolve(path);if(seen.has(path))return;seen.add(path);
    try{const d=JSON.parse(await readFile(path));
      if(d.batches||d.resourceSpans||d.trace?.batches||d.trace?.resourceSpans){all.push(...flatten(d,id));return;}
      const rows=Array.isArray(d)?d:d.traces;assert(Array.isArray(rows),'Not a trace or manifest');
      for(const r of rows)if(!r.path||r.error||r.retrieval_error)retrievalErrors.push({path,id:r.trace_id,error:r.error??r.retrieval_error??'missing path'});
      else await load(resolve(dirname(path),r.path),r.trace_id);
    }catch(e){retrievalErrors.push({path,error:e.message});}}
  for(const p of inputs)await load(p);
  const report={generated_at:new Date().toISOString(),resultPath,inputs,retrieval_errors:retrievalErrors,
    ...analyze(all,JSON.parse(await readFile(resultPath)))};
  await writeFile(out,JSON.stringify(report,null,2)+'\n',{flag:'wx',mode:0o600});
  console.log(JSON.stringify({output:out,...report.summary,issues:report.issues.length,retrieval_errors:retrievalErrors.length,unresolved_predecessor_trace_ids:report.unresolved_predecessor_trace_ids},null,2));
  if(retrievalErrors.length||report.issues.length)process.exitCode=1;
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url))await main();
