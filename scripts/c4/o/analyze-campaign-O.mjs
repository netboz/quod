// O: copied chronological coordinator events, explicit exclusions/lower bound.
// node analyze-campaign-O.mjs OUTPUT.json RESULTS INVENTORY MANIFEST [...]
import {readFile,writeFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
import {flattenO,spanBounds,coordinatorChronology} from './coordinator-chronology.mjs';
import {audit} from './analyze-exact.mjs';
import {inventoryRoots, OWNER_SCOPE, LEGACY_SCOPE} from './coordinator-inventory.mjs';
import {coordinatorAncestry} from './coordinator-ancestry.mjs';
const key=s=>`${s.trace_id}/${s.span_id}`,pk=s=>`${s.trace_id}/${s.parent}`;
const alloc=s=>s.resource['service.instance.id'];
const ns=s=>[BigInt(s.start_ns),BigInt(s.end_ns)];
const ms=n=>Number(n)/1e6;
const duration=s=>{const b=spanBounds(s);return b?ms(b[1]-b[0]):null;};
const a=(s,k)=>s.attributes[k];
const F='quod.foreign.',O='quod.owner.';
const clientStages=new Set(['json_decode','session_admission','decode_and_bind',
  'gateway_signature_verify','local_target_lookup','goal_decode','goal_materialize',
  'response_encode','request_decode','request_crypto_verify']);
// Enclosing HTTP/public-proof/coordinate waits are NOT evidence of the work
// occupying them. In particular outside-prove time is never credited by default.
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

export function analyze(input,results,inventory){
  const issues=[],byId=new Map();
  for(const s of input){const old=byId.get(key(s));
    if(old&&JSON.stringify(old)!==JSON.stringify(s))issues.push({kind:'conflicting_span_copy',key:key(s)});
    else if(!old)byId.set(key(s),s);
  }
  const spans=[...byId.values()];
  const invalidBounds=spans.filter(s=>!spanBounds(s));
  for(const s of invalidBounds){
    issues.push({kind:'invalid_span_timestamp',key:key(s)});
    // O retains malformed coordinator roots as excluded inventory observations.
    // Other span kinds are outside O's partial-report grammar: fail the input,
    // never fabricate their interval or silently remove a client denominator.
    assert(s.name==='quod.dtx.coordinate',`Invalid non-coordinator span timestamp: ${key(s)}`);
  }
  function below(s,ancestor){const seen=new Set();while(s&&!seen.has(key(s))){
    if(key(s)===key(ancestor))return true;seen.add(key(s));s=byId.get(pk(s));}return false;}
  function linkedToTree(s,root){return s.links.some(l=>{const p=byId.get(`${l.trace_id}/${l.span_id}`);return p&&below(p,root);});}
  const coordinates=spans.filter(s=>s.name==='quod.dtx.coordinate').map(s=>{
    const declared=a(s,'quod.dtx.duration_scope'),closure=a(s,'quod.dtx.closure');
    // Old exports have no scope tag. B-only metadata without the tag is not
    // silently assigned legacy meaning; the producer inventory also binds scope.
    const hasOwnerMetadata=closure!==undefined||a(s,'quod.dtx.ancestry')!==undefined||s.events.some(e=>
      ['dtx.done_observed','dtx.worker_error','dtx.coordinator.close_observed','dtx.coordinator_closed'].includes(e.name));
    const duration_scope=declared===OWNER_SCOPE?OWNER_SCOPE:
      declared===undefined&&!hasOwnerMetadata?LEGACY_SCOPE:'unrecognized_duration_scope';
    if(duration_scope==='unrecognized_duration_scope')issues.push({kind:'unknown_coordinator_duration_scope',key:key(s)});
    const owned=duration_scope===OWNER_SCOPE;
    const ancestry=coordinatorAncestry(s,owned,issues);
    const exit_class=a(s,'quod.dtx.exit_class')??null;
    if(owned&&!['worker_exit','retirement_requested','start_failed','owner_terminating'].includes(closure))
      issues.push({kind:'invalid_coordinator_closure',key:key(s)});
    if(owned&&((closure==='worker_exit'&&!['normal','shutdown','killed','abnormal'].includes(exit_class))||
      (closure!=='worker_exit'&&exit_class!==null)))issues.push({kind:'invalid_coordinator_exit_class',key:key(s)});
    // B's child observations happen before notify and cleanup. Neither the
    // close decision nor semantic Complete is an observed child-duration end.
    // Retain the old completed-as-close grammar only for actual legacy roots.
    const chronology=coordinatorChronology(s,duration_scope);
    issues.push(...chronology.issues);
    const excluded=new Set(chronology.exclusion_reasons);
    if(duration_scope==='unrecognized_duration_scope')excluded.add('unknown_coordinator_duration_scope');
    if(!ancestry.ancestry_association_eligible)excluded.add('coordinator_ancestry_ineligible');
    if(owned&&s.events.some(e=>e.name==='dtx.coordinator_closed'))
      issues.push({kind:'obsolete_coordinator_close_event',key:key(s)});
    // Owner release and all B decision/done observations leave a missing final
    // child-stage edge missing, even when semantic Complete was observed.
    // A normal DOWN or retirement without semantic completion is legitimate.
    if(!owned&&!s.events.some(e=>e.name==='dtx.completed'))issues.push({kind:'missing_legacy_group_close_event',key:key(s)});
    if(Number(s.dropped_events)||Number(s.dropped_attributes)||Number(s.dropped_links))issues.push({kind:'dropped_group_metadata',key:key(s)});
    // Keep valid observed intervals for the existing ancestry diagnostics;
    // ancestry still gates client association below. O data/grammar exclusions
    // instead invalidate the intervals themselves and must export none.
    return{span:s,stages:duration_scope==='unrecognized_duration_scope'?[]:chronology.intervals,duration_scope,...ancestry,
      phase_attribution_excluded:excluded.size>0,phase_exclusion_reasons:[...excluded],
      phase_attribution_partial:!excluded.size&&chronology.issues.some(i=>i.kind==='unterminated_group_stage'),
      chronological_event_view:chronology.event_order,endpoint_semantics:chronology.endpoint_semantics,
      duration_meaning:owned?'Owner release of a volatile attempt observation; may include owner mailbox delay and end before child death.':
        duration_scope===LEGACY_SCOPE?'Legacy child process-lifetime wrapper; not an owner-observed attempt or an exact coordinator_total metric.':'Unknown; excluded from request attribution.',
      closure:owned?closure??null:null,exit_class:owned?exit_class:null,
      done_observed:owned&&s.events.some(e=>e.name==='dtx.done_observed'),
      worker_error_observed:owned&&s.events.some(e=>e.name==='dtx.worker_error'),
      coordinator_close_observed:owned&&s.events.some(e=>e.name==='dtx.coordinator.close_observed'),
      coordinator_close_note:owned?'Child close decision observed before the existing done/error notification, not finished cleanup or a child-duration endpoint.':null,
      semantic_completion_observed:owned?s.events.some(e=>e.name==='dtx.completed'):null,
      completion_note:owned?'Actual-done semantic event before notification; not finished child cleanup or a child-duration endpoint. Absence is not a durable verdict. Neither done_observed nor closure establishes Complete.':
        'Legacy dtx.completed was also emitted on failed/uncertain cleanup; it does not establish semantic completion.'};
  });
  const coordinator_inventory=inventoryRoots(coordinates,inventory);
  issues.push(...coordinator_inventory.issues);
  // This is the byte-identical expected-child auditor, not a relaxed B version.
  const exact_audit=invalidBounds.length?{
    status:'not_run_invalid_span_timestamps',issues:[{kind:'exact_audit_invalid_input',keys:invalidBounds.map(key)}],
    summary:{structural_count_pass:false,causal_completeness_claim_permitted:false}
  }:audit(input);
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
      const stage=s.name==='quod.prolog.prove'?'proof_owner':
        s.name.startsWith('quod.client.')&&clientStages.has(s.name.slice(12))?'client_preparation_reply':null;
      if(stage){const [start,end]=ns(s);segments.push({lo:start,hi:end,stage});}
    }
    const groups=coordinates.filter(c=>c.ancestry_association_eligible&&
      (below(c.span,root)||linkedToTree(c.span,root)));
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
      phase_excluded_coordinator_keys:groups.filter(c=>c.phase_attribution_excluded).map(c=>key(c.span)),
      dropped_metadata:related.reduce((n,s)=>n+Number(s.dropped_attributes)+Number(s.dropped_events)+Number(s.dropped_links),0)});
  }
  const workers=spans.filter(s=>s.name===F+'verification_worker');
  const replayStages=spans.filter(s=>s.name===F+'cache_replay');
  const sum=field=>requests.reduce((n,r)=>n+r[field],0),total=sum('observed_ms'),attributed=sum('attributed_ms');
  const means={};for(const r of requests)for(const[k,v]of Object.entries(r.buckets_ms))means[k]=(means[k]??0)+v/requests.length;
  const unresolved=[...new Set(queue.flatMap(q=>q.blockers.flatMap(b=>b.links.filter(l=>!l.resolved).map(l=>l.trace_id))))];
  const excluded_coordinators=coordinates.filter(c=>c.phase_attribution_excluded).map(c=>({
    key:key(c.span),allocation:alloc(c.span)??null,reasons:c.phase_exclusion_reasons}));
  return{schema:'quod.campaign-attribution/coordinator-O-v1',requests,issues,queue,
    excluded_coordinators,
    coordinator_inventory,exact_audit,
    groups:coordinates.map(({span,stages,...observation})=>({...evidence(span),...observation,
      stages:stages.map(s=>({stage:s.stage,duration_ms:ms(s.hi-s.lo)}))})),
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
      attribution_is_lower_bound:true,attribution_denominator_ms:total,
      observed_coordinators:coordinates.length,excluded_coordinator_count:excluded_coordinators.length,
      excluded_coordinator_keys:excluded_coordinators.map(c=>c.key),
      partial_coordinator_count:coordinates.filter(c=>c.phase_attribution_partial).length,
      numerical_95_percent:total>0&&attributed/total>=.95,
      coordinator_inventory_count_pass:coordinator_inventory.summary.count_pass,
      exact_auditor_issue_count:exact_audit.issues.length,
      full_gate_claim_permitted:false},
    unresolved_predecessor_trace_ids:unresolved,
    limits:['Owner attribution only: proof_owner and DTX phase intervals identify owners, not exclusive CPU/functions.',
      'O percentages are an explicit observed-owner lower bound over ALL original request durations, not a complete causal attribution claim. Excluded coordinators remain counted/listed and in the independent attempt inventory.',
      'Wire event order is not causal order. Ambiguous equal-time endpoints, invalid/out-of-span timestamps and dropped-event spans contribute no coordinator phase intervals; no phase-order or insertion-order repair is used.',
      'The SDK may drop newest events at its cap. Stored dropped-event counts invalidate phase attribution even when the retained prefix looks complete. Absent endpoints remain unknown.',
      'owner_observed_attempt is the monitor holder release interval, not child coordinator_total. Do not pool root means across duration scopes.',
      'B close_observed/completed occur before notification and cleanup; neither closes a child interval. Root end/done_observed/retirement also never replace the missing end. Canceled probe/page gaps remain in the unchanged exact auditor.',
      'Required external producer inventory includes failed starts, replacements and unsampled/disabled attempts; matching exports alone cannot prove missing work absent.',
      'A tentative handle lost on callback unwind still belongs in the producer denominator. Root absence cannot identify that cause or manufacture a closure.',
      'no_retained_parent does not distinguish history-only work from a rebuilt row after DOWN; no earlier caller is invented from group or trace identity.',
      'A numeric 95% is insufficient: require unchanged analyze-exact expected counts, export/drop controls, all request roots and same-allocation clock stability.',
      'Missing requests remain full residual, including failures. Purposeful trace samples cannot prove a campaign gate.',
      'No cross-host timestamp subtraction; remote workers are separate diagnostic breakdowns of local waits.',
      'Queue blocker spans are transition markers, not queue duration. Existing owner_stage is the duration owner; age_kind is not job-start age.',
      'Replays/workers are deduplicated by trace/span. Shared worker sums are not per-client latency; replay absence in a partial trace set proves nothing fleet-wide.',
      'Unfetched or unrecorded predecessors remain unknown. No automatic link traversal or reverse-link completeness claim.',
      'A later durable Complete does not change an original pending classification or its observed time-to-pending.']};
}

async function main(){
  const[out,resultPath,inventoryPath,...inputs]=process.argv.slice(2);assert(out&&resultPath&&inventoryPath&&inputs.length,'OUTPUT RESULTS EXTERNAL_PRODUCER_INVENTORY MANIFEST [...]');
  assert(resolve(out).startsWith('/tmp/'),'Scratch output only');
  const all=[],seen=new Set(),retrievalErrors=[];
  async function load(path,id){path=resolve(path);if(seen.has(path))return;seen.add(path);
    try{const d=JSON.parse(await readFile(path));
      if(d.batches||d.resourceSpans||d.trace?.batches||d.trace?.resourceSpans){all.push(...flattenO(d,id));return;}
      const rows=Array.isArray(d)?d:d.traces;assert(Array.isArray(rows),'Not a trace or manifest');
      for(const r of rows)if(!r.path||r.error||r.retrieval_error)retrievalErrors.push({path,id:r.trace_id,error:r.error??r.retrieval_error??'missing path'});
      else await load(resolve(dirname(path),r.path),r.trace_id);
    }catch(e){retrievalErrors.push({path,error:e.message});}}
  for(const p of inputs)await load(p);
  const report={generated_at:new Date().toISOString(),resultPath,inventoryPath,inputs,retrieval_errors:retrievalErrors,
    ...analyze(all,JSON.parse(await readFile(resultPath)),JSON.parse(await readFile(inventoryPath)))};
  await writeFile(out,JSON.stringify(report,null,2)+'\n',{flag:'wx',mode:0o600});
  console.log(JSON.stringify({output:out,...report.summary,issues:report.issues.length,retrieval_errors:retrievalErrors.length,unresolved_predecessor_trace_ids:report.unresolved_predecessor_trace_ids},null,2));
  if(retrievalErrors.length||report.issues.length||report.exact_audit.issues.length)process.exitCode=1;
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url))await main();
