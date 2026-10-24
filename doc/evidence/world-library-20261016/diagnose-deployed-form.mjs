import {chromium} from '../../../_build/lobby-toolkit-20260925/browser/node_modules/playwright/index.mjs'
import {readFileSync,writeFileSync} from 'node:fs'
import {resolve,basename,join} from 'node:path'
process.umask(0o077)
const tree=resolve('_build/world-library-20261016/clean-integration-07/tree')
const out=resolve('_build/world-library-20261016/deployment-01/browser-diagnosis-02')
const context=await chromium.launchPersistentContext(resolve('_build/world-library-20261016/desktop-deployed-02/browser'),{
  executablePath:'/home/yan/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome',headless:true,ignoreHTTPSErrors:true})
try {
 const page=context.pages()[0]
 await page.route('**/__diagnostic',r=>r.fulfill({contentType:'text/html',body:'<!doctype html><title>Read-only diagnosis</title>'}))
 await page.route('**/__acceptance_client/*.js',r=>r.fulfill({contentType:'text/javascript',body:readFileSync(join(tree,'client/src',basename(new URL(r.request().url()).pathname)),'utf8')}))
 await page.goto('https://192.168.1.10:30519/__diagnostic')
 const result=await page.evaluate(async()=>{
  const [k,s,a,w,t,r]=await Promise.all(['key-provider','signed-client','accounts','world','prolog-term','prolog-read'].map(x=>import('/__acceptance_client/'+x+'.js')))
  const identity=await s.authenticateKey(await k.loadActiveKeyProvider()),agent=a.accountReference(identity)
  const pending=(await s.pendingSignedOperations(identity)).map(x=>({id:x.id,context:x.context}))
  const navigation=await w.readSpaceNavigation(identity,agent,null)
  const reads=[]
  for(const [scope,goal] of [
   ['human','gui_pending_questions(Questions).'],
   ['human','gui_receiver_accept(me,Receiver,Capacity).'],
   ['lobby',"','(world_library(Worlds),world_library_status(State))."],
   ['lobby','gui_question_policy(world_creation,Human,Actor).'],
   ['lobby','gui_schema(world_creation,Revision,Tree).'],
   ['lobby','gui_values(world_creation,Token,Values).'],
   ['lobby',"','(current_ontology_identity(Ns,A),','(lobby_owner(Human),gui_responder_for(world_responder,form_ref(Ns,A,world_creation),Human,Hosting)))."],
   ['lobby',"','(current_ontology_identity(Ns,A),','(lobby_owner(Human),gui_native_handler(world_responder,form_ref(Ns,A,world_creation),Human,Hosting,Token)))."],
  ]){
   try{reads.push({scope,goal,reply:await s.signedGoal(identity,{mode:'read',agent,goal:scope==='human'?goal:w.anchoredGoal(navigation.reference,r.readTerm(goal.slice(0,-1)))})})}
   catch(error){reads.push({scope,goal,error:String(error)})}
  }
  return {agent,pending,reads}
 })
 writeFileSync(join(out,'signed-read-diagnosis-02.json'),JSON.stringify(result,null,2)+'\n',{flag:'wx'})
 console.log(JSON.stringify(result,null,2))
} finally {await context.close()}
