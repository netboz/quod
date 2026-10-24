// Exercises the same owner-signed request prepared for Wild Realm, using only
// the agent-owned profile and Highland Retreat. No key or session is exported.
import { chromium } from '../../../_build/lobby-toolkit-20260925/browser/node_modules/playwright/index.mjs'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { resolve, basename, join } from 'node:path'
import assert from 'node:assert/strict'
process.umask(0o077)
const label = process.argv[2]
assert.match(label, /^owner-appearance-[0-9]+$/)
const out = resolve('_build/terrain-presentation-20261017', label)
mkdirSync(out)
const deployment = '_build/terrain-presentation-20261017/deployment-274-rolling'
assert.equal(JSON.parse(readFileSync(join(deployment, 'shared-appearance-verify-03/result.json'), 'utf8')).verified, true)
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
    const [k,s,a,w,t,l] = await Promise.all(['key-provider','signed-client','accounts','world','prolog-term','space-library'].map(x => import('/__acceptance_client/' + x + '.js')))
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
    const goal = `transaction((${source.replace(/\.$/, '')},${cleanup})).`
    window.operation = { identity, agent, goal, signedGoal: s.signedGoal, pending: s.pendingSignedOperations,
      stateGoal, verifyGoal, before, singleBinding: w.singleBinding }
    return { namespace: distant.namespace, labels: worlds.map(row => row.label), goal, verifyGoal, definitionsBefore: before }
  }, source)
  writeFileSync(join(out, 'prepared.json'), JSON.stringify(preparation, null, 2) + '\n', { flag: 'wx' })
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
} finally { await context.close() }
