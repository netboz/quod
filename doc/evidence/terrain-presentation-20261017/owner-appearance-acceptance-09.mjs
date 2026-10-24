// Exercises the same owner-signed request prepared for Wild Realm, using only
// the agent-owned profile and Highland Retreat. No key or session is exported.
import { chromium } from '../../../_build/lobby-toolkit-20260925/browser/node_modules/playwright/index.mjs'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { resolve, basename, join } from 'node:path'
import assert from 'node:assert/strict'
process.umask(0o077)
const label = process.argv[2]
const validateOnly = process.argv[3] === '--validate-only'
const prepareOnly = validateOnly || process.argv[3] === '--prepare-only'
assert.match(label, /^owner-appearance-[0-9]+$/)
const out = resolve('_build/terrain-presentation-20261017', label)
mkdirSync(out)
const deployment = '_build/terrain-presentation-20261017/deployment-274-rolling'
assert.equal(JSON.parse(readFileSync(join(deployment, 'shared-appearance-verify-05/result.json'), 'utf8')).verified, true)
const source = readFileSync(join(deployment, 'acceptance-owner-update.pl'), 'utf8').trim()
const context = await chromium.launchPersistentContext(resolve('_build/world-library-20261016/desktop-deployed-04/browser'), {
  executablePath: '/home/yan/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', headless: true, ignoreHTTPSErrors: true,
})
try {
  const page = context.pages()[0]
  await page.route('**/__owner_appearance', r => r.fulfill({ contentType: 'text/html', body: '<!doctype html><title>Own-account appearance acceptance</title>' }))
  await page.route('**/__acceptance_client/*.js', r => r.fulfill({ contentType: 'text/javascript',
    body: readFileSync(join('client/src', basename(new URL(r.request().url()).pathname)), 'utf8') }))
  await page.goto('https://192.168.1.10:30519/__owner_appearance')
  const preparation = await page.evaluate(async source => {
    const [k,s,a,w,t,l,r] = await Promise.all(['key-provider','signed-client','accounts','world','prolog-term','space-library','prolog-read'].map(x => import('/__acceptance_client/' + x + '.js')))
    const identity = await s.authenticateKey(await k.loadActiveKeyProvider()), agent = a.accountReference(identity)
    await s.resolveSignedOperations(identity, { onTerminal: (_reply, operation) => operation.context?.flow === 'terrain_presentation_acceptance' })
    if ((await s.pendingSignedOperations(identity)).length) throw new Error('Unresolved operation; no submission.')
    const navigation = await w.readSpaceNavigation(identity, agent)
    const reply = await s.signedGoal(identity, { mode: 'read', agent,
      goal: w.anchoredGoal(navigation.reference, t.compound('world_library', [t.variable('Worlds')])) })
    const worlds = l.readWorldLibrary(w.singleBinding(reply, 'Worlds'))
    if (worlds.length !== 2 || !['Distant Heights','Highland Retreat'].every(label => worlds.some(row => row.label === label))) throw new Error('Wrong acceptance account.')
    const distant = worlds.find(row => row.label === 'Distant Heights').reference
    const highland = worlds.find(row => row.label === 'Highland Retreat').reference
    const world = t.variable('W'), revision = t.variable('R'), spec = t.variable('S')
    const stateGoal = w.anchoredGoal(distant, t.compound('findall', [t.compound('definition', [world, revision, spec]),
      t.compound(',', [t.compound('lobby_terrain_world', [world]), t.compound('voxel_world_definition', [world, revision, spec])]), t.variable('Definitions')]))
    const before = w.singleBinding(await s.signedGoal(identity, { mode: 'read', agent, goal: stateGoal }), 'Definitions')
    const c = t.compound, v = t.variable, a0 = t.atom, bytes = value => t.binary(new TextEncoder().encode(value))
    const all = goals => goals.reduceRight((tail, head) => tail ? c(',', [head, tail]) : head, null)
    const marks = v('Marks'), mark = c('mark', [v('_'),bytes('sky_sphere'),v('_'),v('_'),v('_'),v('_'),v('_')])
    const sw = v('SkyWorld'), sn = v('SkyNamespace'), sa = v('SkyAnchor')
    const membership = c('space_member', [sw,c('entity_ref',[sn,sa,c('world_sky',[sw])])])
    const rule = c(',', [c('lobby_terrain_world',[sw]),c('current_ontology_identity',[sn,sa])])
    const verifyGoal = w.anchoredGoal(highland, all([
      c('voxel_presentation',[highland.instance,bytes('terrain'),v('Palette'),v('_'),v('_')]),
      c('member',[c('material',[{type:'number',value:1},c('surface',[v('_'),v('_'),v('_'),v('_'),v('Textures')])]),v('Palette')]),
      c('member',[c('texture',[bytes('base_colour'),v('_'),v('_')]),v('Textures')]),
      c('instance_of',[a0('sky_sphere'),c('world_sky',[highland.instance])]),
      c('attribute',[a0('personal_sky'),a0('brightness'),{type:'number',value:1000}]),
      c('clause',[membership,rule]),
      c('world_view',[distant.instance,a0('playing'),marks]),
      c('findall',[a0('sky'),c('member',[mark,marks]),{type:'list',items:[a0('sky')],tail:null}]),
    ]))
    // Retire the direct membership introduced by our earlier fixture in the
    // same transaction that installs the normal shared derived membership.
    const cleanup = w.anchoredGoal(distant, t.compound('retract', [t.compound('space_member', [distant.instance,
      t.compound('entity_ref', [t.binary(new TextEncoder().encode(distant.namespace)), t.binary(distant.anchor), t.compound('world_sky', [distant.instance])])])])).replace(/\.$/, '')
    // The normal editing flow prepares code with a signed read and only then
    // executes the compiled goal. Large edit terms never become write results.
    if (!source.startsWith('transaction((') || !source.endsWith(')).')) throw new Error('Unexpected reviewed request shape.')
    const pieces = source.slice('transaction(('.length, -3).split('call(E0),call(E1),')
    if (pieces.length !== 2) throw new Error('Unexpected compiler boundary.')
    const preparationGoal = `${pieces[0]}Apply = transaction((E0,E1,${pieces[1]})).`
    const prepared = await s.signedGoal(identity, { mode: 'read', agent, goal: preparationGoal })
    const applied = r.readTerm(w.singleBinding(prepared, 'Apply'))
    // Reuse the complete existing world projection for every affected world.
    // Negation is the supported universal check here.
    const checkAllWorlds = c('\\+',[all([
      c('lobby_terrain_world',[v('CheckedWorld')]),
      c('\\+',[c('world_view',[v('CheckedWorld'),a0('playing'),v('_')])]),
    ])])
    const validationGoal = w.anchoredGoal(distant,checkAllWorlds).replace(/\.$/,'')
    const goal = `transaction((${t.formatTerm(applied)},${cleanup},${validationGoal})).`
    // Retain a portable owner request using the same compiled edits. Only the
    // exact target identity and fixture label change; source guards stay exact.
    const equal = (left, right) => left.length === right.length && left.every((n,i) => n === right[i])
    const generalize = term => {
      if (term.type === 'binary') {
        if (equal(term.value, new TextEncoder().encode(distant.namespace))) return v('OwnerLobby')
        if (equal(term.value, distant.anchor)) return v('OwnerAnchor')
        if (equal(term.value, new TextEncoder().encode('Highland Retreat'))) return bytes('Wild Realm')
      }
      if (term.type === 'compound') return c(term.functor,term.args.map(generalize))
      if (term.type === 'list') return {...term,items:term.items.map(generalize),tail:term.tail && generalize(term.tail)}
      return term
    }
    const portable = t.formatClause(c('transaction',[all([
      c('lobby_reference',[c('ontology_ref',[v('OwnerLobby'),v('OwnerAnchor')])]),generalize(applied),
      c('::',[v('OwnerLobby'),all([
        c('current_ontology_identity',[v('OwnerLobby'),v('OwnerAnchor')]),checkAllWorlds,
      ])]),
    ])]))
    window.operation = { identity, agent, goal, signedGoal: s.signedGoal, pending: s.pendingSignedOperations,
      stateGoal, verifyGoal, before, singleBinding: w.singleBinding, distant, checkAllWorlds }
    return { namespace: distant.namespace, labels: worlds.map(row => row.label), goal, portable, preparationGoal, verifyGoal, definitionsBefore: before }
  }, source)
  writeFileSync(join(out, 'prepared.json'), JSON.stringify(preparation, null, 2) + '\n', { flag: 'wx' })
  writeFileSync(join(out, 'wild-realm-owner-update.pl'), preparation.portable + '\n', { flag: 'wx' })
  if (validateOnly) {
    const validation = await page.evaluate(async () => {
      const {identity,agent,distant,checkAllWorlds} = window.operation
      const [s,w,t] = await Promise.all(['signed-client','world','prolog-term'].map(x => import('/__acceptance_client/'+x+'.js')))
      const c=t.compound,v=t.variable,all=goals=>goals.reduceRight((tail,head)=>tail?c(',',[head,tail]):head,null)
      const state=c('findall',[c('sky',[v('W'),v('K'),v('V')]),all([
        c('lobby_terrain_world',[v('W')]),c('attribute',[c('world_sky',[v('W')]),v('K'),v('V')]),
      ]),v('Skies')])
      const read = goal => s.signedGoal(identity,{mode:'read',agent,goal:w.anchoredGoal(distant,goal)})
      const before=w.singleBinding(await read(state),'Skies')
      const positive=await read(checkAllWorlds)
      const skyMark=c('attribute',[c('world_sky',[distant.instance]),t.atom('mark_id'),t.binary(new TextEncoder().encode('sky'))])
      const staged=await s.signedGoal(identity,{mode:'cursor',agent,goal:w.anchoredGoal(distant,c('transaction',[all([
        c('retract',[skyMark]),c('assertz',[skyMark]),checkAllWorlds,
      ])]))})
      if (staged.result === 'solution') await s.signedCursorCommand(identity,staged.cursor,'stop')
      const broken=c('transaction',[all([c('retract',[skyMark]),checkAllWorlds])])
      const negative=await s.signedGoal(identity,{mode:'cursor',agent,goal:w.anchoredGoal(distant,broken)})
      if (negative.result === 'solution') await s.signedCursorCommand(identity,negative.cursor,'stop')
      const after=w.singleBinding(await read(state),'Skies'),restored=await read(checkAllWorlds)
      return {positive,stagedPositive:{result:staged.result,accepted:false},negative,restored,skyAttributesUnchanged:before===after,pending:(await s.pendingSignedOperations(identity)).length,accepted:false}
    })
    writeFileSync(join(out,'validation.json'),JSON.stringify(validation,null,2)+'\n',{flag:'wx'})
    assert.equal(validation.positive.result,'ok');assert.equal(validation.stagedPositive.result,'solution');assert.equal(validation.negative.result,'fail')
    assert.equal(validation.restored.result,'ok');assert.equal(validation.skyAttributesUnchanged,true);assert.equal(validation.pending,0)
    console.log(JSON.stringify({validation:true,accepted:false,skyAttributesUnchanged:true}))
  } else if (prepareOnly) { console.log(JSON.stringify({ prepared: true, submitted: false, bytes: preparation.goal.length })); } else {
  const result = await page.evaluate(async () => {
    const { identity, agent, goal, signedGoal, pending, stateGoal, verifyGoal, before, singleBinding } = window.operation
    const { committed } = await import('/__acceptance_client/space-entry.js')
    const reply = await signedGoal(identity, { mode: 'execute', agent, goal }, {
      context: { flow: 'terrain_presentation_acceptance' }, onTerminal: () => true,
    })
    const after = singleBinding(await signedGoal(identity, { mode: 'read', agent, goal: stateGoal }), 'Definitions')
    const appearance = await signedGoal(identity, { mode: 'read', agent, goal: verifyGoal })
    return { reply, committed: committed(reply), pending: (await pending(identity)).length,
      definitionsAfter: after, definitionsUnchanged: before === after, appearance }
  })
  writeFileSync(join(out, 'result.json'), JSON.stringify(result, null, 2) + '\n', { flag: 'wx' })
  assert.equal(result.pending, 0)
  assert.equal(result.committed, true)
  assert.equal(result.definitionsUnchanged, true)
  assert.equal(result.appearance.result, 'ok')
  console.log(JSON.stringify({ result: result.reply.result, pending: result.pending }))
  }
} finally { await context.close() }
