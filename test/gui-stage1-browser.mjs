import fs from 'node:fs/promises'
import readline from 'node:readline'
import assert from 'node:assert/strict'
import { createServer } from '../ui/node_modules/vite/dist/node/index.js'

const { chromium } = await import(process.env.QUOD_PLAYWRIGHT_MODULE)
const fixture = JSON.parse(await fs.readFile(process.argv[2], 'utf8'))
const clientBase = `/@fs${new URL('../client/', import.meta.url).pathname}`
const input = readline.createInterface({ input: process.stdin })
async function control(action) {
  const answer = new Promise(resolve => input.once('line', resolve))
  process.stdout.write(`COMMAND ${JSON.stringify({ action })}\n`)
  assert.equal(await answer, 'ok')
}
const target = `https://127.0.0.1:${fixture.port}`
const server = await createServer({ root: 'ui', configFile: 'ui/vite.config.ts',
  optimizeDeps: { entries: ['world.html', '../client/test/operation-panel.fixture.js'] },
  server: { host: '127.0.0.1', port: 0, proxy: Object.fromEntries([
    '/api/auth', '/api/goals', '/api/agents', '/api/views', '/api/ontologies/system',
  ].map(path => [path, { target, secure: false, ws: path === '/api/views' }])) } })
await server.listen()
const url = `http://127.0.0.1:${server.httpServer.address().port}/world.html`
const browser = await chromium.launch({ headless: true, args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] })
let submits = 0
const errors = []
let lastPage
async function device() {
  const context = await browser.newContext()
  await context.addInitScript(() => Object.defineProperty(navigator, 'xr', { value: {
    isSessionSupported: async () => true, addEventListener() {}, removeEventListener() {},
  } }))
  const page = await context.newPage()
  lastPage = page
  page.setDefaultTimeout(15000)
  page.on('pageerror', error => errors.push(error.message))
  page.on('request', request => { if (request.url().endsWith('/api/agents/instructions')) submits++ })
  await page.goto(url)
  await page.evaluate(async ({ f, clientBase }) => {
    const { fromB64url, storeActiveKeyProvider } = await import(`${clientBase}src/key-provider.js`)
    const prefix = new Uint8Array([48,46,2,1,0,48,5,6,3,43,101,112,4,34,4,32])
    const privateBytes = new Uint8Array([...prefix, ...fromB64url(f.private)])
    const privateKey = await crypto.subtle.importKey('pkcs8', privateBytes, 'Ed25519', true, ['sign'])
    const publicKey = await crypto.subtle.importKey('raw', fromB64url(f.public), 'Ed25519', true, ['verify'])
    await storeActiveKeyProvider({ keyPair: { publicKey, privateKey }, accounts: [{
      network: f.network, namespace: f.namespace, anchor: f.anchor, instanceText: 'me.',
    }] })
  }, { f: fixture, clientBase })
  await page.reload()
  await page.getByRole('button', { name: 'Create / operations', exact: true }).click()
  await page.getByLabel('Storage ontology', { exact: true }).waitFor()
  return { page, context }
}
async function choose(page, name = 'Create space', storage = fixture.namespace) {
  await page.getByLabel('Storage ontology', { exact: true }).selectOption({ label: storage })
  await page.getByLabel('Class', { exact: true }).selectOption('space')
  await page.getByLabel('Operation', { exact: true }).selectOption({ label: name })
  await page.getByRole('button', { name: 'Create', exact: true }).waitFor()
}
async function outcome(page, expected) {
  await page.waitForFunction(expected => [...document.querySelectorAll('input')].some(input =>
    input.readOnly && !input.disabled && input.value.includes(expected)), expected)
}
async function result(page) { return page.getByLabel('Committed result', { exact: true }).inputValue() }

try {
  const first = await device(), page = first.page
  await choose(page)
  assert.equal(await page.getByLabel('Name', { exact: true }).inputValue(), 'Space')
  assert.equal(await page.getByLabel('Width (X)', { exact: true }).inputValue(), '100')
  await page.getByLabel('Name', { exact: true }).fill('Unsent workshop')
  await page.getByRole('button', { name: 'Cancel / close', exact: true }).click()
  await page.getByRole('button', { name: 'Create / operations', exact: true }).click()
  assert.equal(await page.getByLabel('Name', { exact: true }).inputValue(), 'Unsent workshop')
  await page.getByRole('button', { name: 'Use current fields and defaults', exact: true }).click()

  await control('stop_agent')
  await page.getByRole('button', { name: 'Create', exact: true }).click()
  await outcome(page, 'agent_unavailable')
  await control('start_agent')

  // The request reaches the real listener; only its first response is dropped.
  let dropped = 0
  await page.route('**/api/agents/instructions', async route => {
    const response = await route.fetch()
    const reply = await response.json()
    console.log('Dropped real reply:', JSON.stringify({ status: response.status(), result: reply.result, reasons: reply.reasons }))
    dropped++; await route.abort('connectionreset')
  }, { times: 1 })
  await page.getByRole('button', { name: 'Create', exact: true }).click()
  await outcome(page, 'uncertain')
  assert.equal(dropped, 1)
  assert.equal(await page.getByRole('button', { name: 'Create', exact: true }).isEnabled(), false)
  await page.getByRole('button', { name: 'Check original outcome', exact: true }).click()
  await outcome(page, 'committed')
  const ordinary = await result(page)
  assert.match(ordinary, /entity_ref/); assert.match(ordinary, /unplaced/)
  console.log('PASS normal UI defaults, cancellation, lost ordinary reply and exact original recovery')

  await page.getByRole('button', { name: 'Use current fields and defaults', exact: true }).click()
  await page.getByLabel('Name', { exact: true }).fill('Atomic workshop')
  await page.getByLabel('Width (X)', { exact: true }).fill('120')
  await page.getByLabel('Placement', { exact: true }).selectOption({ label: 'Remote room' })
  await page.evaluate(async clientBase => {
    const { installSoftwareXR } = await import(`${clientBase}test/operation-panel.fixture.js`)
    installSoftwareXR()
  }, clientBase)
  await page.getByRole('button', { name: 'Cancel / close', exact: true }).click()
  await page.getByRole('button', { name: 'Enter VR', exact: true }).click()
  await page.getByRole('button', { name: 'VR active', exact: true }).waitFor()
  await page.getByRole('button', { name: 'Create / operations', exact: true }).click()
  const typed = await page.evaluate(async clientBase => {
    const { spatialType } = await import(`${clientBase}test/operation-panel.fixture.js`)
    return spatialType('space_name', '!')
  }, clientBase)
  assert.equal(typed, 'Atomic workshop!')
  await page.route('**/api/agents/instructions', async route => { await route.fetch(); await route.abort('connectionreset') }, { times: 1 })
  await page.evaluate(async clientBase => {
    const { spatialSubmit } = await import(`${clientBase}test/operation-panel.fixture.js`)
    spatialSubmit('space_create_submit')
  }, clientBase)
  await outcome(page, 'uncertain')
  // Another browser has this authorized identity and no local journal at all.
  const second = await device()
  await outcome(second.page, 'committed')
  const atomic = await result(second.page)
  assert.match(atomic, /creation-destination/)
  await page.evaluate(async clientBase => {
    const { signedOperationJournal } = await import(`${clientBase}src/operation-journal.js`)
    const journal = signedOperationJournal()
    for (const row of await journal.list()) await journal.delete(row.id)
  }, clientBase)
  await first.context.close()
  await control('delete_created'); await control('restart')
  await second.context.close()
  const third = await device(), current = third.page
  await outcome(current, 'committed')
  assert.equal(await result(current), atomic)
  const history = current.getByLabel('Previous instruction', { exact: true })
  const originals = await history.locator('option').evaluateAll(options => options.map(option => option.value).filter(Boolean))
  assert.equal(originals.length, 2)
  const recovered = []
  for (const id of originals) {
    await history.selectOption(id)
    await current.getByRole('button', { name: 'Check original outcome', exact: true }).click()
    await current.waitForFunction(() => !document.querySelector('input[readonly]')?.disabled)
    recovered.push(await result(current))
  }
  assert.deepEqual(new Set(recovered), new Set([ordinary, atomic]))
  console.log('PASS lost atomic reply, fresh device with empty journal, deletion with retained history and runtime restart')

  await control('place_agent')
  await choose(current, 'Create infinite space')
  await control('deny')
  await current.getByRole('button', { name: 'Create', exact: true }).click()
  await outcome(current, 'refused')
  await control('allow')
  await current.getByRole('button', { name: 'Create', exact: true }).click()
  await outcome(current, 'committed')
  assert.match(await result(current), /transform\(1200,300,400,0,45,0\)/)
  const rendered = await current.evaluate(async ({ clientBase, results }) => {
    const { renderedSubject } = await import(`${clientBase}test/operation-panel.fixture.js`)
    return renderedSubject(results)
  }, { clientBase, results: await result(current) })
  assert.deepEqual(rendered, { position: [1.2, 0.3, 0.4], boxes: 1 })
  console.log('PASS real policy refusal, infinite authored form and placement near A')

  await current.getByLabel('Class', { exact: true }).selectOption('note')
  await current.getByLabel('Note name', { exact: true }).fill('A note')
  await current.getByRole('button', { name: 'Save note', exact: true }).click()
  await outcome(current, 'committed')
  await current.getByRole('button', { name: 'Open returned subject', exact: true }).click()
  await current.getByLabel('Note name', { exact: true }).fill('A revised note')
  await current.getByRole('button', { name: 'Save note', exact: true }).click()
  await outcome(current, 'committed')
  console.log('PASS non-space class creation and exact-instance opening/rename through normal UI')

  await current.getByRole('button', { name: 'Cancel / close', exact: true }).click()
  await current.getByRole('button', { name: 'Create / operations', exact: true }).click()
  await choose(current, 'Create space', fixture.storage)
  await current.getByLabel('Name', { exact: true }).fill('Foreign workshop')
  await current.getByLabel('Placement', { exact: true }).selectOption({ label: 'Foreign room' })
  await control('deny_placement')
  await current.getByRole('button', { name: 'Create', exact: true }).click()
  await outcome(current, 'refused')
  await control('allow_placement')
  await control('arm_conflict')
  await current.getByRole('button', { name: 'Adopt current fields, keeping draft', exact: true }).click()
  assert.equal(await current.getByLabel('Name', { exact: true }).inputValue(), 'Foreign workshop')
  await current.getByRole('button', { name: 'Create', exact: true }).click()
  await outcome(current, 'conflict_retry')
  await control('disarm_conflict')
  await current.getByRole('button', { name: 'Adopt current fields, keeping draft', exact: true }).click()
  await control('arm_revocation')
  await current.getByRole('button', { name: 'Adopt current fields, keeping draft', exact: true }).click()
  await current.getByRole('button', { name: 'Create', exact: true }).click()
  // Yan's confirmed boundary: disabling the human key blocks new instructions;
  // accepted work may finish under the distinct agent's still-valid permission.
  await outcome(current, 'committed')
  assert.match(await result(current), /creation-storage/)
  await control('restore_human'); await control('disarm_conflict')
  await current.getByRole('button', { name: 'Refresh operations', exact: true }).click()
  await current.getByRole('button', { name: 'Adopt current fields, keeping draft', exact: true }).click()
  assert.equal(await current.getByRole('button', { name: 'Create', exact: true }).isEnabled(), false)
  await current.getByRole('button', { name: 'Use current fields and defaults', exact: true }).click()
  await current.getByLabel('Name', { exact: true }).fill('After key restoration')
  await current.getByLabel('Placement', { exact: true }).selectOption({ label: 'Foreign room' })
  await current.route('**/api/agents/instructions', async route => {
    await control('revoke_human')
    const response = await route.fetch()
    assert.notEqual(response.status(), 200)
    await control('restore_human')
    await route.fulfill({ response })
  }, { times: 1 })
  await current.getByRole('button', { name: 'Create', exact: true }).click()
  await outcome(current, 'refused')
  await current.getByRole('button', { name: 'Refresh operations', exact: true }).click()
  await current.getByRole('button', { name: 'Create', exact: true }).click()
  await outcome(current, 'committed')
  assert.match(await result(current), /creation-storage/)
  console.log('PASS signed foreign discovery, denied placement, OCC conflict, revocation before custody and subsequent creation')
  await control('verify')
  assert.equal(submits, 12, 'recovery and reopening never resubmit creation')
  assert.deepEqual(errors, [])
  console.log(JSON.stringify({ result: 'passed', submits, hardwareHeadset: 'not run' }))
} catch (error) {
  if (lastPage && !lastPage.isClosed()) {
    console.error('UI failure:', await lastPage.locator('body').innerText())
    console.error('Browser errors:', errors)
    console.error('Status:', await lastPage.getByLabel('Status', { exact: true }).inputValue().catch(() => 'absent'))
    await lastPage.screenshot({ path: `${process.argv[2]}.png`, fullPage: true })
  }
  throw error
} finally {
  await browser.close(); await server.close(); input.close()
}
