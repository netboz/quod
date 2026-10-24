import { chromium } from '../../../_build/lobby-toolkit-20260925/browser/node_modules/playwright/index.mjs'
import { mkdirSync, writeFileSync, existsSync } from 'node:fs'
import { resolve, join } from 'node:path'
import { readControl } from '../../../client/src/locomotion.js'
import assert from 'node:assert/strict'

process.umask(0o077)
const [label, profile, url = 'https://192.168.1.10:30519/', world = 'Distant Heights'] = process.argv.slice(2)
assert.match(label, /^[a-z0-9-]+$/)
const out = resolve('_build/terrain-presentation-20261017', label)
mkdirSync(out, { recursive: true })
const result = { events: [], errors: [], poses: [], phase: 'opening', url, world }
const save = () => writeFileSync(join(out, 'observation.json'), JSON.stringify(result, null, 2) + '\n')
const event = value => { result.events.push(value); save() }
const context = await chromium.launchPersistentContext(resolve(profile), {
  executablePath: '/home/yan/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome',
  headless: true, ignoreHTTPSErrors: true, viewport: { width: 1440, height: 1000 },
})
const page = context.pages()[0]
page.setDefaultTimeout(60000)
if (process.env.QUOD_PREVIEW_TREE) {
  // A fulfilled main document has no network address classification. Grant
  // this test origin Chromium's ordinary LAN permission for its live socket.
  await context.grantPermissions(['local-network-access'], { origin: new URL(url).origin })
  const publicRoot = resolve(process.env.QUOD_PREVIEW_TREE, 'priv/explorer')
  await page.route('**/*', route => {
    const path = new URL(route.request().url()).pathname
    const local = resolve(publicRoot, path === '/' ? 'world.html' : '.' + path)
    if ((path === '/' || path.startsWith('/assets/')) && local.startsWith(publicRoot + '/') && existsSync(local))
      return route.fulfill({ path: local })
    return route.continue()
  })
}
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
    if (['projection', 'terrain_manifest', 'terrain_chunk', 'terrain_complete', 'unavailable'].includes(m.type))
      result.events.push({ at: Date.now(), type: m.type, selection: m.selection, interest: m.interest_seq,
        chunks: m.chunks?.length, index: m.index, encodedBytes: m.payload?.length, reason: m.reason })
  })
  s.on('framesent', e => {
    const m = JSON.parse(String(e.payload))
    if (s === socket && m.type === 'terrain_interest') result.events.push({ ...m, at: Date.now() })
    if (s === socket && m.type === 'terrain_ack') result.events.push({ at: Date.now(), type: m.type,
      want: m.want?.length, chunk: m.chunk, complete: m.complete })
  })
})
try {
  save()
  await page.goto(url)
  await page.getByText('Physical space ready.', { exact: true }).waitFor()
  await page.getByRole('button', { name: 'My worlds', exact: true }).click()
  const panel = page.getByRole('region', { name: 'My worlds', exact: true })
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
  result.phase = 'walking'; result.before = pose(); save()
  await page.evaluate(() => { window.__captured = new Promise(resolve => document.addEventListener('pointerlockchange', resolve, { once: true })) })
  await page.locator('canvas').click({ position: { x: 1100, y: 500 } })
  await page.evaluate(() => window.__captured)
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
  for (const key of ['ArrowLeft', 'ArrowRight']) {
    await page.keyboard.down(key)
    // Fixed durations measure travel in both directions, not readiness retries.
    await page.evaluate(() => new Promise(resolve => setTimeout(resolve, 10000)))
    await page.keyboard.up(key)
  }
  result.after = pose()
  result.rendering = await page.evaluate(() => window.__terrainEvidence)
  result.text = await page.locator('body').innerText()
  result.phase = 'observed'; save()
  await page.screenshot({ path: join(out, 'after.png') })
  await page.evaluate(() => document.exitPointerLock())
  await page.getByRole('button', { name: 'Return to lobby', exact: true }).first().click()
  await page.getByRole('heading', { name: 'Personal lobby', exact: true }).waitFor()
  console.log(JSON.stringify({ ...result.rendering, errors: result.errors, before: result.before, after: result.after }))
} catch (error) {
  result.failure = String(error); save()
  await page.screenshot({ path: join(out, 'failure.png') }).catch(() => {})
  throw error
} finally { await context.close(); save() }
