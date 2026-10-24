import { chromium } from '../../../_build/lobby-toolkit-20260925/browser/node_modules/playwright/index.mjs'
import { mkdirSync, writeFileSync } from 'node:fs'
import { resolve, join } from 'node:path'
import { readControl } from '../../../client/src/locomotion.js'
import assert from 'node:assert/strict'

process.umask(0o077)
const [label, profile, url, world] = process.argv.slice(2)
assert.match(label, /^[a-z0-9-]+$/)
assert.equal(url, 'https://192.168.1.10:30519/')
assert.ok(world, 'Select the acceptance world explicitly')
assert.ok(!process.env.QUOD_PREVIEW_TREE, 'Acceptance must use the deployed client bundle')
const out = resolve('_build/terrain-presentation-20261017', label)
mkdirSync(out)
const result = { events: [], errors: [], poses: [], phase: 'opening', url, world, previewTree: null }
const save = () => writeFileSync(join(out, 'observation.json'), JSON.stringify(result, null, 2) + '\n')
const event = value => { result.events.push(value); save() }
const context = await chromium.launchPersistentContext(resolve(profile), {
  executablePath: '/home/yan/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome',
  headless: true, ignoreHTTPSErrors: true, viewport: { width: 1440, height: 1000 },
})
const page = context.pages()[0]
page.setDefaultTimeout(60000)
let latest, control, socket
const pose = () => latest?.poses.find(p => p.body === control?.body)?.position
page.on('pageerror', e => result.errors.push(e.message))
page.on('console', m => { if (m.type() === 'error') event({ type: 'console_error', message: m.text() }) })
page.on('requestfailed', r => result.events.push({ type: 'requestfailed', url: r.url(), failure: r.failure() }))
page.on('websocket', s => {
  s.on('socketerror', error => event({ type: 'socketerror', url: s.url(), error }))
  s.on('close', () => event({ type: 'socketclose', url: s.url() }))
  s.on('framereceived', e => {
    const m = JSON.parse(String(e.payload))
    if (s !== socket) result.events.push({ at: Date.now(), type: m.type, reason: m.reason, selection: m.selection })
    if (m.type === 'projection' && m.selection === 'active') { socket = s; control = readControl(m.control) }
    if (s !== socket) return
    if (m.frame) { latest = m.frame; result.poses.push({ at: Date.now(), position: pose() }) }
    if (['projection', 'terrain_manifest', 'terrain_chunks', 'unavailable'].includes(m.type))
      result.events.push({ at: Date.now(), type: m.type, selection: m.selection, interest: m.interest_seq,
        chunks: m.chunks?.length, complete: m.complete, frameBytes: Buffer.byteLength(String(e.payload)), encodedBytes: m.chunks?.reduce((sum, row) => sum + (row.payload?.length ?? 0), 0), reason: m.reason })
  })
  s.on('framesent', e => {
    const m = JSON.parse(String(e.payload))
    if (s === socket && m.type === 'terrain_interest') result.events.push({ ...m, at: Date.now() })
    if (s === socket && m.type === 'terrain_ack') result.events.push({ at: Date.now(), type: m.type,
      want: m.want?.length, through: m.through, complete: m.complete })
  })
})
try {
  save()
  await page.goto(url)
  await page.getByText('Physical space ready.', { exact: true }).waitFor()
  await page.getByRole('button', { name: 'My worlds', exact: true }).click()
  const panel = page.getByRole('region', { name: 'My worlds', exact: true })
  if (process.env.QUOD_CREATE_ACCEPTANCE_WORLD === '1') {
    const names = await panel.getByLabel('World', { exact: true }).locator('option').allTextContents()
    assert.ok(names.includes('Distant Heights') && names.includes('Highland Retreat'), 'Agent-owned account')
    assert.ok(!names.includes(world), 'No resubmission of a world creation')
    await panel.getByRole('button', { name: 'Create world', exact: true }).click()
    const form = page.getByRole('region', { name: 'Create world', exact: true })
    await form.waitFor()
    await form.getByLabel('World name (optional)', { exact: true }).fill(world)
    await form.getByLabel('Landscape', { exact: true }).selectOption('meadow')
    await form.getByLabel('Ground detail', { exact: true }).selectOption('1000')
    result.creation = { name: world, landscape: 'meadow', spacing: 1000, at: Date.now() }; save()
    await form.getByRole('button', { name: 'Create world', exact: true }).click()
    await page.waitForFunction(() => !document.body.innerText.includes('Questions awaiting your attention'))
    await form.getByRole('button', { name: 'Close', exact: true }).click()
    await page.getByRole('button', { name: 'My worlds', exact: true }).click()
  }
  await panel.getByLabel('World', { exact: true }).selectOption({ label: world })
  await panel.getByRole('button', { name: 'Enter world', exact: true }).click()
  await page.getByRole('heading', { name: world, exact: true }).waitFor()
  await page.getByText('Physical space ready.', { exact: true }).waitFor()
  const store = await page.evaluate(() => performance.getEntriesByType('resource').map(r => r.name)
    .find(name => /\/engineStore-[^/]+\.js$/.test(name)))
  assert.ok(store, 'loaded engine module')
  await page.evaluate(async path => {
    const exports = await import(path)
    const EngineStore = Object.values(exports).find(v => v?.LastCreatedScene)
    const scene = EngineStore.LastCreatedScene
    window.__terrainEvidence = { frames: 0, hidden: 0, changes: [] }
    let previous
    scene.onAfterRenderObservable.add(() => {
      const roots = scene.transformNodes.filter(n => n.name.startsWith('mark:') && n.getChildren().some(c => c.name.startsWith('terrain:')))
      const enabled = roots.filter(n => n.isEnabled()).length
      const status = document.querySelector('.world-panel [role=status]')?.textContent
      const state = JSON.stringify([roots.length, enabled, status])
      const record = window.__terrainEvidence
      record.frames++
      if (roots.length && enabled === 0) record.hidden++
      if (state !== previous) {
        previous = state
        record.changes.push({ at: Date.now(), roots: roots.length, enabled, status, camera: scene.activeCamera.globalPosition.asArray() })
      }
    })
  }, store)
  await page.screenshot({ path: join(out, 'before.png') })
  result.phase = 'walking'; result.walkStarted = Date.now(); result.before = pose(); save()
  await page.evaluate(() => { window.__captured = new Promise(resolve => document.addEventListener('pointerlockchange', resolve, { once: true })) })
  await page.locator('canvas').click({ position: { x: 1100, y: 500 } })
  await page.evaluate(() => window.__captured)
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
  for (const key of ['ArrowLeft', 'ArrowRight', 'ArrowLeft', 'ArrowRight']) {
    await page.keyboard.down(key)
    // Fixed durations measure travel in both directions, not readiness retries.
    await page.evaluate(() => new Promise(resolve => setTimeout(resolve, 10000)))
    await page.keyboard.up(key)
  }
  result.after = pose()
  result.rendering = await page.evaluate(() => window.__terrainEvidence)
  result.text = await page.locator('body').innerText()
  result.appearance = await page.evaluate(async path => {
    const exports = await import(path), engine = Object.values(exports).find(v => v?.LastCreatedScene)
    const scene = engine.LastCreatedScene
    return { skies: scene.meshes.filter(m => m.metadata?.sky && m.isEnabled()).length,
      texturedMaterials: scene.materials.filter(m => m.albedoTexture && !m.unlit).length,
      readyTexturedMaterials: scene.materials.filter(m => m.albedoTexture && !m.unlit && m.albedoTexture.isReady()).length }
  }, store)
  const walking = result.poses.filter(p => p.at >= result.walkStarted && p.position)
  const distance = (a, b) => Math.hypot(a[0]-b[0], a[2]-b[2])
  const excursion = Math.max(0, ...walking.map(p => distance(p.position, result.before)))
  const interests = result.events.filter(e => e.type === 'terrain_interest' && e.at >= result.walkStarted).length
  const content = result.events.filter(e => e.type === 'terrain_chunks')
  result.acceptance = { excursion, interests, contentMessages: content.length,
    maximumPoseGapMs: Math.max(0, ...walking.slice(1).map((p, i) => p.at-walking[i].at)),
    renderedFrames: result.rendering.frames, hiddenFrames: result.rendering.hidden }
  result.phase = 'observed'; save()
  assert.equal(result.errors.length, 0, 'No page errors')
  assert.deepEqual(result.events.filter(e => ['console_error', 'socketerror', 'unavailable'].includes(e.type)), [], 'No rendering or delivery errors')
  assert.equal(result.rendering.hidden, 0, 'Verified terrain stays visible while walking')
  assert.ok(result.rendering.frames > 100, 'Movement was rendered throughout the observation')
  assert.ok(excursion > 8 && interests >= 4, 'Sustained walking crossed several chunk boundaries')
  assert.ok(content.length >= 4, 'Observed the new bounded content delivery')
  assert.ok(content.every(message => message.frameBytes <= 512*1024), 'Every deployed content frame fits the unchanged reply guard')
  assert.ok(content.some(message => message.complete === false), 'The deployed window actually crossed a batch boundary')
  assert.ok(content.some(message => message.encodedBytes > 0), 'Content messages carried actual terrain bytes')
  assert.ok(result.acceptance.maximumPoseGapMs < 2000, 'No multi-second pose stalls while walking')
  assert.equal(result.appearance.skies, 1, 'One enabled authored sky')
  assert.ok(result.appearance.texturedMaterials > 0, 'Textured surfaces are installed')
  assert.equal(result.appearance.readyTexturedMaterials, result.appearance.texturedMaterials, 'Installed textures are ready')
  await page.screenshot({ path: join(out, 'after.png') })
  await page.evaluate(() => document.exitPointerLock())
  await page.getByRole('button', { name: 'Return to lobby', exact: true }).first().click()
  await page.getByRole('heading', { name: 'Personal lobby', exact: true }).waitFor()
  writeFileSync(join(out, 'PASSED.json'), JSON.stringify({ passed: true, url, world, previewTree: null,
    created: result.creation ?? null, ...result.acceptance, appearance: result.appearance }, null, 2) + '\n', { flag: 'wx' }); console.log(JSON.stringify(result.acceptance))
} catch (error) {
  result.failure = String(error); save()
  await page.screenshot({ path: join(out, 'failure.png') }).catch(() => {})
  throw error
} finally { await context.close(); save() }
