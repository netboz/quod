// Public deterministic M0 examples derived from the existing browser owners.
import {readFile,writeFile} from 'node:fs/promises'
import {createPrivateKey,webcrypto} from 'node:crypto'
import assert from 'node:assert/strict'
import {encodeGoalRequest} from '../../../client/src/signed-client.js'
import {importEncryptedKeyProvider,b64url,fromB64url} from '../../../client/src/key-provider.js'
import {readTerm} from '../../../client/src/prolog-read.js'
import {renderTerm,binary,compound,atom} from '../../../client/src/prolog-term.js'
import {readMarks} from '../../../client/src/marks.js'

const root=new URL('../../../',import.meta.url)
const corpus=JSON.parse(await readFile(new URL('client/test/fixtures/native-contract/contracts.json',root)))
const provider=await importEncryptedKeyProvider(corpus.bundle,corpus.passphrase)
const seed=Uint8Array.from({length:32},(_,i)=>i+33)
const privateKey=createPrivateKey({key:Buffer.concat([Buffer.from('302e020100300506032b657004220420','hex'),seed]),format:'der',type:'pkcs8'})
const jwk=privateKey.export({format:'jwk'})
const akey=await webcrypto.subtle.importKey('jwk',jwk,{name:'Ed25519'},false,['sign'])
const anchor=new Uint8Array(32).fill(8), network=new Uint8Array(32).fill(7)
const u={namespace:'human:public-m0',anchor,instanceText:'me.'}
const a={...u,instanceText:'personal.'}
assert.notEqual(b64url(provider.publicKey),jwk.x)
const requests=[]
for(const [name,actor,publicKey,goal,mode] of [
 ['human-offers',u,provider.publicKey,'gui_operations(entity_ref(<<"human:public-m0">>,Anchor,me),Views).','read'],
 ['agent-controller-save',a,fromB64url(jwk.x),'gui_operation(entity_ref(<<"human:public-m0">>,Anchor,me),controller_settings,Revision,controller_save,Fields,Results).','execute'],
 ['agent-space-create',a,fromB64url(jwk.x),'gui_operation(class_ref(<<"storage:public-m0">>,Anchor,space),create,Revision,space_create_submit,Fields,Results).','execute'],
]) {
  // Concrete terms use public fixture bytes. Revisions/fields are symbolic here;
  // production seams in the acceptance map supply their actual bound values.
  const fixed=goal.replaceAll('Anchor',renderTerm(binary(anchor)))
  readTerm(fixed.replace(/\.$/,''))
  const operation=new Uint8Array(32).fill(requests.length+11)
  const bytes=encodeGoalRequest({networkIdentity:network,signingPublicKey:publicKey,operationId:operation,agentNamespace:actor.namespace,agentAnchor:anchor,agentInstanceText:actor.instanceText,mode,notAfterMs:'1900000000000',goal:fixed})
  const signature=publicKey===provider.publicKey?await provider.sign(bytes):await webcrypto.subtle.sign('Ed25519',akey,bytes)
  requests.push({name,actor:{...actor,anchor:b64url(anchor)},mode,goal:fixed,deadline:'1900000000000',public_key:b64url(publicKey),bytes:b64url(bytes),signature:b64url(new Uint8Array(signature))})
}
const data={notice:'Public fixture keys only. Symbolic revision/fields are wire examples, not executable permission grants.',human_key:b64url(provider.publicKey),agent_key:jwk.x,requests,
  result_examples:['[result(revision,1)]','[result(space,entity_ref(<<"storage:public-m0">>,Anchor,<<"01ARZ3NDEKTSV4RRFFQ69G5FAV">>)),result(location,placed(entity_ref(<<"human:public-m0">>,Anchor,<<"01ARZ3NDEKTSV4RRFFQ69G5FAT">>),transform(1000,0,0,0,0,0)))]'].map(s=>s.replaceAll('Anchor',renderTerm(binary(anchor))))}
for(const term of data.result_examples)readTerm(term)
await writeFile(new URL('wire-contract.json',import.meta.url),JSON.stringify(data,null,2)+'\n')

const depict=(ns,id)=>renderTerm(compound('depicts',[binary(new TextEncoder().encode(ns)),binary(anchor),atom(id)]))
const mark=(id,at,subject)=>`mark(<<"${id}">>,<<"group">>,[],${at},no_surface,unlabelled,${subject})`
const scene=`[${[
 mark('s1','transform(1000,200,0,0,90,0)',depict('storage:s1','s1')),
 mark('s1/s2','relative(<<"s1">>,transform(0,300,2000,0,0,90))',depict('storage:s2','s2')),
 mark('s1/s2/object','relative(<<"s1/s2">>,transform(100,0,0,0,0,0))',depict('storage:object','object')),
].join(',')}]`
const marks=readMarks(scene);assert.equal(marks.length,3);assert.equal(marks[2].depicts.ontology,'storage:object')
const recursive={status:'M0 contract fixture; live recursive server expansion and physical-domain integration are M3 acceptance, not installed here.',scene,
  local_transforms_mm_degrees:[[1000,200,0,0,90,0],[0,300,2000,0,0,90],[100,0,0,0,0,0]],expected_object_origin_mm:[3000,600,0],
  exact_subjects:marks.map(m=>({namespace:m.depicts.ontology,anchor:b64url(m.depicts.anchor),entity:renderTerm(m.depicts.entity)})),
  obligations:[
   {case:'S0→S1→S2 contents',expected:'all contents exposed recursively with no entry'},
   {case:'second independent S2 display',expected:'distinct occurrence path; same exact subject; no duplicated physical body'},
   {case:'S2→S1 cycle',expected:'explicit cycle occurrence; no recursive expansion of repeated ancestor'},
   {case:'source denied/revoked or wrong anchor',expected:'refuse/withdraw affected exposure; no private marks, empty success or cube fallback'},
   {case:'unchanged renewal',expected:'retained readers/native resources; zero replay/rebuild/write/sync'},
   {case:'real source update',expected:'only dependent exposure updates; physical body revision and geometry agree'},
   {case:'cross-boundary physics',expected:'shared authoritative domain/frame; contact and control agree with rendered coordinates'},
   {case:'independent active simulation conflict',expected:'explicit refusal until governed custody/transfer transition; no visual-only success'},
  ],wireframe:{default_extent_mm:[100000,100000,100000],default_bounds_mm:[-50000,-50000,-50000,50000,50000,50000],asymmetric_extent_mm:[2000,3000,5000],rational_example:'box(q(1/3,<<"mm">>),q(3,<<"m">>),q(5,<<"m">>))',infinite:'unavailable for finite wire box; no fake bounds or cube fallback',collision:false}}
await writeFile(new URL('recursive-contract.json',import.meta.url),JSON.stringify(recursive,null,2)+'\n')
if(process.env.M0_BACKUP){const clean=await importEncryptedKeyProvider(await readFile(process.env.M0_BACKUP,'utf8'),corpus.passphrase);assert.equal(b64url(clean.publicKey),corpus.public_key);assert.equal(b64url(new Uint8Array(await clean.sign(fromB64url(corpus.requests[0].bytes)))),corpus.requests[0].signature);console.log('Exported managed backup imported and signed through browser owner')}
console.log('U/A wire bytes, exact results and nested scene fixtures verified')
