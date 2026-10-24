// Installs the authored appearance in the agent-owned acceptance world only.
// Uses the ordinary signed transaction and journal; never retries a write.
import { chromium } from '../../../_build/lobby-toolkit-20260925/browser/node_modules/playwright/index.mjs'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { resolve, basename, join } from 'node:path'
import assert from 'node:assert/strict'
process.umask(0o077)
const label = process.argv[2]
assert.match(label, /^appearance-fixture-[0-9]+$/)
const out = resolve('_build/terrain-presentation-20261017', label)
mkdirSync(out)
const old = readFileSync('doc/evidence/terrain-presentation-20261017/before/priv/ontologies/lobby_worlds.pl', 'utf8')
const source = readFileSync('priv/ontologies/quod_lobby.pl', 'utf8')
const previous = old.match(/world_palette\((\[[\s\S]*?\])\)\./)[1]
const palette = source.match(/world_palette\((\[[\s\S]*?\])\) :-/)[1]
const worldSource = readFileSync('priv/ontologies/lobby_worlds.pl', 'utf8')
const sky = worldSource.slice(worldSource.indexOf('assertz(instance_of(sky_sphere,world_sky(W)))'),
  worldSource.indexOf('world_palette(Palette),world_render_resources(Resources)')).trim()
const context = await chromium.launchPersistentContext(resolve('_build/world-library-20261016/desktop-deployed-04/browser'), {
  executablePath: '/home/yan/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome',
  headless: true, ignoreHTTPSErrors: true,
})
try {
  const page = context.pages()[0]
  await page.route('**/__appearance_fixture', r => r.fulfill({ contentType: 'text/html', body: '<!doctype html><title>Acceptance world appearance</title>' }))
  await page.route('**/__acceptance_client/*.js', r => r.fulfill({ contentType: 'text/javascript',
    body: readFileSync(join('client/src', basename(new URL(r.request().url()).pathname)), 'utf8') }))
  await page.goto('https://192.168.1.10:30519/__appearance_fixture')
  const preparation = await page.evaluate(async ({ previous, palette, sky }) => {
    const [k,s,a,w,t,l,r] = await Promise.all(['key-provider','signed-client','accounts','world','prolog-term','space-library','prolog-read']
      .map(x => import('/__acceptance_client/' + x + '.js')))
    const identity = await s.authenticateKey(await k.loadActiveKeyProvider()), agent = a.accountReference(identity)
    await s.resolveSignedOperations(identity, { onTerminal: (_reply, operation) => operation.context?.flow === 'terrain_appearance_acceptance' })
    if ((await s.pendingSignedOperations(identity)).length) throw new Error('Unresolved operation; fixture will not submit.')
    const navigation = await w.readSpaceNavigation(identity, agent)
    const reply = await s.signedGoal(identity, { mode: 'read', agent,
      goal: w.anchoredGoal(navigation.reference, t.compound('world_library', [t.variable('Worlds')])) })
    const worlds = l.readWorldLibrary(w.singleBinding(reply, 'Worlds'))
    const matches = worlds.filter(row => row.label === 'Distant Heights')
    if (matches.length !== 1 || !worlds.some(row => row.label === 'Highland Retreat')) throw new Error('Expected acceptance library is missing.')
    const world = matches[0].reference
    const catalogue = await s.readSystemOntologies(identity)
    const material = catalogue.filter(row => row.namespace === 'quod:material:eidolons')
    if (material.length !== 1) throw new Error('Material catalogue unavailable.')
    const assets = [['babylon_grass', 'GrassAsset'], ['babylon_ground', 'GroundAsset']].map(([name, value]) =>
      w.anchoredGoal({ ...material[0], anchor: k.fromB64url(material[0].anchor) },
        r.readTerm(`texture_asset(${name},<<"base_colour">>,${value},_)`)).replace(/\.$/, '')).join(',')
    const ns = t.formatTerm(t.binary(new TextEncoder().encode(world.namespace)))
    const anchor = t.formatTerm(t.binary(world.anchor))
    const goal = `${ns}::(current_ontology_identity(${ns},${anchor}),transaction((
      W = ${t.formatTerm(world.instance)}, current_principal(Human),lobby_owner(Human),voxel_world_owner(W,Human),
      findall(presentation(Id,P,V,R),voxel_presentation(W,Id,P,V,R),[presentation(<<"terrain">>,${previous},View,Resources)]),
      \\+ instance_of(sky_sphere,world_sky(W)),
      ${assets},
      Grass = texture(<<"base_colour">>,GrassAsset,repeat(500,500)),
      Ground = texture(<<"base_colour">>,GroundAsset,repeat(500,500)),
      retract(voxel_presentation(W,<<"terrain">>,${previous},View,Resources)),
      assertz(voxel_presentation(W,<<"terrain">>,${palette},View,Resources)),
      ${sky}
      assertz(space_member(W,entity_ref(${ns},${anchor},world_sky(W)))),voxel_validate_presentation(W)))).`
    window.fixture = { identity, agent, goal, signedGoal: s.signedGoal, pending: s.pendingSignedOperations }
    return { namespace: world.namespace, label: matches[0].label, goal }
  }, { previous, palette, sky })
  writeFileSync(join(out, 'prepared.json'), JSON.stringify(preparation, null, 2) + '\n', { flag: 'wx' })
  assert.equal(preparation.label, 'Distant Heights')
  const result = await page.evaluate(async () => {
    const { identity, agent, goal, signedGoal, pending } = window.fixture
    const { committed } = await import('/__acceptance_client/space-entry.js')
    const reply = await signedGoal(identity, { mode: 'execute', agent, goal }, {
      context: { flow: 'terrain_appearance_acceptance' }, onTerminal: () => true,
    })
    return { reply, committed: committed(reply), pending: (await pending(identity)).length }
  })
  writeFileSync(join(out, 'result.json'), JSON.stringify(result, null, 2) + '\n', { flag: 'wx' })
  console.log(JSON.stringify({ label: preparation.label, result: result.reply.result, pending: result.pending }))
  assert.equal(result.pending, 0)
  assert.equal(result.committed, true)
} finally { await context.close() }
