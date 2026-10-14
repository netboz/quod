import assert from 'node:assert/strict'

export async function checkSessionEntry(page, origin) {
  await page.clock.install()
  await page.route('**/session-entry-fixture', route => route.fulfill({ contentType: 'text/html', body: '<div id="fixture"></div>' }))
  await page.goto(origin + '/session-entry-fixture')
  const path = new URL('./session-entry.fixture.tsx', import.meta.url).pathname
  await page.evaluate(async path => {
    const refresh = await import('/@react-refresh')
    refresh.default.injectIntoGlobalHook(window)
    window.$RefreshReg$ = () => {}
    window.$RefreshSig$ = () => type => type
    window.__vite_plugin_react_preamble_installed__ = true
    const { createSessionEntryFixture } = await import(`/@fs${path}`)
    window.sessionFixture = await createSessionEntryFixture()
  }, path)
  const configure = options => page.evaluate(options => window.sessionFixture.configure(options), options)
  const stats = () => page.evaluate(() => window.sessionFixture.stats())
  const scene = page.getByRole('region', { name: 'Test scene', includeHidden: true })
  const draft = page.getByLabel('Unsaved work')
  try {
    await page.getByRole('heading', { name: 'Opening your space…' }).waitFor()
    assert.equal((await stats()).mounts, 0, 'startup does not mount an unauthorized scene')
    await configure({ ready: true })
    await draft.waitFor()
    await draft.fill('keep my edits')
    await page.clock.fastForward(60_001)
    await page.getByRole('heading', { name: 'Your session has expired' }).waitFor()
    assert.equal(await scene.isVisible(), false)
    assert.equal(await scene.evaluate(node => node.parentElement.inert), true)
    assert.equal(await draft.inputValue(), 'keep my edits')
    assert.equal(await page.getByRole('button', { name: 'Create account' }).count(), 0)
    await configure({ failRestore: true })
    await page.getByRole('button', { name: 'Restore session' }).click()
    await page.getByRole('alert').getByText('The gateway is unavailable.').waitFor()
    assert.equal(await scene.isVisible(), false)
    await configure({ failRestore: false })
    await page.getByRole('button', { name: 'Restore session' }).click()
    await draft.waitFor()
    assert.equal(await draft.inputValue(), 'keep my edits')
    assert.equal((await stats()).mounts, 1, 'restore keeps the opened scene mounted')
    // Expiry discovered after a background tab resumes uses the same screen.
    await page.clock.setSystemTime(Date.now() + 1_000_000)
    await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange')))
    await page.getByRole('heading', { name: 'Your session has expired' }).waitFor()
    assert.equal(await scene.isVisible(), false)
    return await stats()
  } finally { await page.evaluate(() => window.sessionFixture.dispose()) }
}
