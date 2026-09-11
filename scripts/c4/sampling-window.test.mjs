import test from 'node:test';import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {samplingWindow,restoreSamplingWindow} from './sampling-window.mjs';
const before=readFileSync(new URL('../../deploy/quod.nomad',import.meta.url),'utf8');
test('only two sampler values change to always_on and inverse restores exact bytes',()=>{
 const p=samplingWindow(before);assert.equal(p.diff.length,2);
 assert.equal(p.during.replaceAll('OTEL_TRACES_SAMPLER=always_on','OTEL_TRACES_SAMPLER=parentbased_traceidratio'),before);
 assert.equal(p.during.split('OTEL_TRACES_SAMPLER_ARG=0.05').length-1,2);
 assert.equal(restoreSamplingWindow(p.during,p),before);
});
test('drift is refused without automatic overwrite or deploy',()=>{
 const p=samplingWindow(before);assert.throws(()=>restoreSamplingWindow(p.during+'\n',p),/drift/);
 assert.throws(()=>samplingWindow(p.during),/unexpected_sampler/);
 assert.throws(()=>samplingWindow(before.replace('parentbased_traceidratio','always_on')),/unexpected_sampler/);
});
