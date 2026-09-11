// Pure plan only: no file writes, Nomad calls, deploy, sampling mutation or
// automatic rollback. The explicit deploy workflow saves both exact versions.
import {createHash} from 'node:crypto';
const beforeLine='OTEL_TRACES_SAMPLER=parentbased_traceidratio';
const duringLine='OTEL_TRACES_SAMPLER=always_on';
const sha=text=>createHash('sha256').update(text).digest('hex');
export function samplingWindow(before) {
 if(typeof before!=='string') throw Error('invalid_template');
 const lines=before.split('\n'),positions=[];
 for(let i=0;i<lines.length;i++) if(lines[i].startsWith('OTEL_TRACES_SAMPLER=')) {
   if(lines[i]!==beforeLine||lines[i+1]!=='OTEL_TRACES_SAMPLER_ARG=0.05')
     throw Error('unexpected_sampler_template');
   positions.push(i);
 }
 if(positions.length!==2) throw Error('unexpected_sampler_template_population');
 const changed=lines.slice();for(const i of positions) changed[i]=duringLine;
 const during=changed.join('\n');
 return {before,during,before_sha256:sha(before),during_sha256:sha(during),
  diff:positions.map(i=>({line:i+1,before:beforeLine,during:duringLine})),
  caveat:'Always-on sampling, including unsampled parents. The pinned SDK ignores the unchanged ratio argument. Verify effective cached samplers and every attempt flag; configuration alone does not prove export.'};
}
export function restoreSamplingWindow(current,plan) {
 if(sha(current)!==plan.during_sha256||sha(plan.before)!==plan.before_sha256)
   throw Error('configuration_drift_do_not_overwrite');
 const rebuilt=samplingWindow(plan.before);
 if(rebuilt.during!==current) throw Error('invalid_sampling_plan');
 return plan.before;
}
