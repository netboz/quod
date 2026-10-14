import { pathToFileURL } from 'node:url'
import { chromium } from '/home/yan/src/quod/_build/lobby-toolkit-20260925/browser/node_modules/playwright/index.mjs'
import { writeFile, mkdir } from 'node:fs/promises'
import assert from 'node:assert/strict'

const tree = '/home/yan/src/quod/_build/ontology-eidolons-20261014/corrections-02/tree'
const evidence = new URL('./browser-01/', import.meta.url)
await mkdir(evidence)
const { createServer } = await import(pathToFileURL(`${tree}/ui/node_modules/vite/dist/node/index.js`))
const server = await createServer({ root: `${tree}/ui`, configFile: `${tree}/ui/vite.config.ts`,
  server: { host: '127.0.0.1', port: 0, fs: { allow: [tree] } } })
const started = new Date().toISOString()
let browser
const errors = []
try {
  await server.listen()
  const origin = `http://127.0.0.1:${server.httpServer.address().port}`
  browser = await chromium.launch({ headless: true,
    executablePath: '/home/yan/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome' })
  const context = await browser.newContext({ viewport: { width: 1000, height: 900 } })
  const page = await context.newPage()
  page.on('pageerror', error => errors.push(error.message))
  const { checkOntologyInspection } = await import(pathToFileURL(`${tree}/ui/test/ontology-inspection.browser.mjs`))
  const result = await checkOntologyInspection(page, origin, `${tree}/ui/test/ontology-inspection.fixture.tsx`)
  assert.deepEqual(errors, [])
  await writeFile(new URL('result.json', evidence), JSON.stringify({ started, finished: new Date().toISOString(), result, errors }, null, 2)+'\n')
  console.log(JSON.stringify({ result, errors }))
} catch (error) {
  await writeFile(new URL('FAILURE.json', evidence), JSON.stringify({ started, error: String(error), errors }, null, 2)+'\n')
  throw error
} finally {
  await browser?.close()
  await server.close()
}
