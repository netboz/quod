import assert from 'node:assert/strict'

// Browser projection simulation complements the signed real-owner EUnit cases.
export async function checkOntologyInspection(page, origin, fixturePath = new URL('./ontology-inspection.fixture.tsx', import.meta.url).pathname) {
  await page.route('**/ontology-inspection-fixture', route => route.fulfill({ contentType: 'text/html', body: '<div id="fixture"></div>' }))
  await page.goto(`${origin}/ontology-inspection-fixture`)
  await page.evaluate(async path => {
    const refresh = await import('/@react-refresh')
    refresh.default.injectIntoGlobalHook(window)
    window.$RefreshReg$ = () => {}
    window.$RefreshSig$ = () => type => type
    window.__vite_plugin_react_preamble_installed__ = true
    const { createInspectionFixture } = await import(`/@fs${path}`)
    window.inspectionFixture = createInspectionFixture()
  }, fixturePath)
  try {
    await page.getByText('can_invoke(read, reader, [], target). % é', { exact: false }).waitFor()
    assert.equal(await page.locator('textarea').count(), 0)
    assert.equal(await page.getByRole('button', { name: /Save|Accept|Preview/ }).count(), 0)
    let calls = await page.evaluate(() => window.inspectionFixture.calls)
    assert.deepEqual(calls.map(call => call.method), ['POST', 'POST', 'DELETE'])
    const request = Buffer.from(calls[0].request, 'base64url').toString('utf8')
    assert.ok(request.includes('ontology_policy'))
    assert.ok(request.includes('ontology_ref(<<"inspection:target">>'))
    await page.evaluate(() => window.inspectionFixture.configure({ value: 'can_invoke(updated, reader, [], target).\n' }))
    await page.getByRole('button', { name: 'Refresh', exact: true }).click()
    await page.getByText('can_invoke(updated, reader, [], target).', { exact: false }).waitFor()
    await page.evaluate(() => window.inspectionFixture.configure({ denied: true }))
    await page.getByRole('button', { name: 'Refresh', exact: true }).click()
    await page.getByRole('alert').waitFor()
    assert.ok((await page.getByRole('alert').textContent()).includes('not allowed'))
    assert.equal(await page.locator('pre').count(), 0)
    calls = await page.evaluate(() => window.inspectionFixture.calls)
    assert.equal(calls.filter(call => call.url === '/api/goals/cursors').length, 3)
    assert.ok(calls.every(call => !call.url.includes('/execute')))
    await page.getByRole('button', { name: 'Close', exact: true }).click()
    await page.getByRole('heading').waitFor({ state: 'detached' })
    return { readonlyLens: true, exactTarget: true, completeUtf8: true, refreshed: true, denialClearedContent: true, executeRequests: 0 }
  } finally { await page.evaluate(() => window.inspectionFixture.dispose()) }
}
