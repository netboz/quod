import { chromium } from '../../../_build/lobby-toolkit-20260925/browser/node_modules/playwright/index.mjs'
import { mkdirSync, writeFileSync } from 'node:fs'
import { resolve, join } from 'node:path'
import { once } from 'node:events'
process.umask(0o077)
const out = resolve('_build/terrain-presentation-20261017/credit-diagnostic-02')
mkdirSync(out)
const events = []
const save = () => writeFileSync(join(out, 'events.json'), JSON.stringify(events, null, 2))
let captured
const manifestAcknowledged = new Promise(resolve => { captured = resolve })
const context = await chromium.launchPersistentContext(resolve('_build/world-library-20261016/desktop-deployed-04/browser'), {
  executablePath: '/home/yan/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', headless: true, ignoreHTTPSErrors: true,
})
const page = context.pages()[0]
page.on('websocket', socket => {
  const observe = (direction, event) => {
    const m = JSON.parse(String(event.payload))
    if (m.type === 'open') return
    events.push({ at: Date.now(), direction, type: m.type, view: m.view, tick: m.tick ?? m.frame?.tick,
      origin: m.origin_seq ?? m.frame?.origin_seq, want: m.want?.length, complete: m.complete,
      interest: m.interest_seq, chunks: m.chunks?.length, selection: m.selection, reason: m.reason })
    save()
    if (direction === 'sent' && m.type === 'terrain_ack' && m.want) captured()
  }
  socket.on('framereceived', e => observe('received', e))
  socket.on('framesent', e => observe('sent', e))
})
try {
  await page.goto('https://192.168.1.10:30519/')
  await page.getByText('Physical space ready.', { exact: true }).waitFor()
  await page.getByRole('button', { name: 'My worlds', exact: true }).click()
  const panel = page.getByRole('region', { name: 'My worlds', exact: true })
  await panel.getByLabel('World', { exact: true }).selectOption({ label: 'Distant Heights' })
  await panel.getByRole('button', { name: 'Enter world', exact: true }).click()
  await Promise.race([manifestAcknowledged, new Promise((_, reject) => setTimeout(() => reject(Error('No manifest acknowledgement')), 60000))])
  console.log('MANIFEST_ACKNOWLEDGED: inspect the live owner now')
  process.stdin.resume()
  await once(process.stdin, 'data')
  await page.screenshot({ path: join(out, 'scene.png') })
  writeFileSync(join(out, 'text.txt'), await page.locator('body').innerText())
} finally {
  await context.close()
  process.stdin.pause()
  save()
}
