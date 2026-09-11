// Offline only. Writes a fresh report; never overwrites evidence or contacts a fleet.
import {readFile,writeFile} from 'node:fs/promises';
import {analyzePhase1} from './phase1-analysis.mjs';
const [out,capturesFile,...traceFiles]=process.argv.slice(2);
if(!out||!capturesFile)throw Error('usage: OUTPUT CAPTURES_JSON [FULL_TRACE_JSON ...]');
const captures=JSON.parse(await readFile(capturesFile,'utf8'));
const traces=await Promise.all(traceFiles.map(async p=>JSON.parse(await readFile(p,'utf8'))));
const report=analyzePhase1({captures,traces});
await writeFile(out,JSON.stringify(report,null,2)+'\n',{flag:'wx'});
