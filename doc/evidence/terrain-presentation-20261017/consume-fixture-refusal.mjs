// Consume the already received, definite proof refusal. This is the same local
// journal deletion normally performed by signed-client's onTerminal callback.
import { chromium } from '../../../_build/lobby-toolkit-20260925/browser/node_modules/playwright/index.mjs'
import { readFileSync, writeFileSync } from 'node:fs'
import { resolve, basename, join } from 'node:path'
import assert from 'node:assert/strict'
process.umask(0o077)
const receipt = JSON.parse(readFileSync('_build/terrain-presentation-20261017/appearance-fixture-02/result.json'))
assert.equal(receipt.reply.result, 'fail')
assert.equal(receipt.reply.request_digest, 'vpQfUSSw5PikII6fyAj2iz66y0-BftDGjACOFYYp-_A')
const context = await chromium.launchPersistentContext(resolve('_build/world-library-20261016/desktop-deployed-04/browser'), {
  executablePath: '/home/yan/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', headless: true, ignoreHTTPSErrors: true,
})
try {
  const page = context.pages()[0]
  await page.route('**/__fixture_refusal', r => r.fulfill({ contentType: 'text/html', body: '<!doctype html><title>Consume known fixture refusal</title>' }))
  await page.route('**/__acceptance_client/*.js', r => r.fulfill({ contentType: 'text/javascript', body: readFileSync(join('client/src', basename(new URL(r.request().url()).pathname)), 'utf8') }))
  await page.goto('https://192.168.1.10:30519/__fixture_refusal')
  const result = await page.evaluate(async digest => {
    const [k,s,j] = await Promise.all(['key-provider','signed-client','operation-journal'].map(x => import('/__acceptance_client/' + x + '.js')))
    const identity = await s.authenticateKey(await k.loadActiveKeyProvider())
    const rows = await s.pendingSignedOperations(identity)
    const matching = rows.filter(row => row.id === digest && row.context?.flow === 'terrain_appearance_acceptance')
    if (matching.length !== 1) throw new Error('Known refused fixture row is absent or ambiguous.')
    await j.signedOperationJournal().delete(digest)
    return { consumed_definite_refusal: digest, pending: (await s.pendingSignedOperations(identity)).length }
  }, receipt.reply.request_digest)
  writeFileSync('_build/terrain-presentation-20261017/consumed-fixture-refusal.json', JSON.stringify(result, null, 2) + '\n', { flag: 'wx' })
  console.log(JSON.stringify(result))
} finally { await context.close() }
