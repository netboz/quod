import assert from 'node:assert/strict'
import { worldProjection, advanceSimulation } from './client/src/simulation.js'
const message = {type:'projection',view:'retained',height:'4',expires_ms:String(Date.now()+30000),marks:'[]',selection:'nonphysical'}
const named=worldProjection({...message,name:'Library'})
assert.equal(named.name,'Library');assert.equal(named.marks.length,0);assert.equal(named.control,null)
console.log('PASS governed name does not invent contents or control')
assert.equal(worldProjection({...message,name:null}).name,null)
assert.throws(()=>worldProjection({...message,name:42}),/authored space name/)
console.log('PASS absent name remains explicit and malformed names refuse')
for(const selection of ['nonphysical','disabled','denied','recovering','unavailable']) {
 const view=worldProjection({...message,name:'Library',selection})
 assert.equal(view.selection,selection);assert.equal(advanceSimulation(view,{view:'retained'}),view)
 assert.throws(()=>worldProjection({...message,name:'Library',selection,frame:{}}),/selection/)
}
console.log('PASS name cannot override selection or admit a physical frame')
assert.throws(()=>worldProjection({...message,name:'Library',expires_ms:'1'}),/expired/)
console.log('PASS name cannot override absolute authorization expiry')
const anchor='a'.repeat(32)
const marks=`[mark(<<"child">>,<<"box">>,[f(<<"width">>,500),f(<<"height">>,500),f(<<"depth">>,500)],transform(0,0,0,0,0,0),surface(<<"#6A90D9">>,0,700,0,[]),label(<<"Library">>,<<"above">>),depicts(<<"owner">>,<<"${anchor}">>,child))]`
const view=worldProjection({...message,name:'Parent',marks})
assert.equal(view.marks.length,1);assert.equal(view.name,'Parent');assert.equal(view.marks[0].label.text,'Library')
assert.equal(view.marks[0].depicts.ontology,'owner')
console.log('PASS authored child caption remains separate from current place and exact depicted identity')
console.log('SPACE_BROWSER_PASS')
