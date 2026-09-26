import assert from 'node:assert/strict'

// Run against the UI's Vite server with a browser page supplied by the caller.
// Real Babylon controls/rendering are exercised without a headset or backend.
export async function checkProofPanel(page, origin) {
  await page.route('**/proof-panel-fixture', route => route.fulfill({
    contentType: 'text/html', body: '<style>body{margin:0}canvas{width:100vw;height:100vh}</style><canvas id="scene"></canvas>',
  }))
  await page.goto(`${origin}/proof-panel-fixture`)
  const base = new URL('../', import.meta.url).pathname
  const result = await page.evaluate(async base => {
    const { exerciseProofPanel } = await import(`/@fs${base}test/proof-panel.fixture.js`)
    return exerciseProofPanel()
  }, base)
  assert.equal(result.typed, 'a(X).')
  assert.deepEqual(result.calls, ['run', 'next', 'accept', 'stop', 'close'])
  assert.ok(result.resultText.includes('Binding59 = value(59)'))
  for (const field of ['scrollable', 'locked', 'sameMesh', 'hidden', 'retired', 'frontFacing',
    'cancelled', 'spatialOpen', 'spatialClosed']) assert.equal(result[field], true, field)
  assert.equal(result.activations, 1)
  assert.deepEqual(result.modes, [true, false])
  return result
}
