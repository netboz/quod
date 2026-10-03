import assert from 'node:assert/strict'

// Run against the UI's Vite server with a browser page supplied by the caller.
// Real Babylon controls/rendering are exercised without a headset or backend.
export async function checkWorkspacePanel(page, origin) {
  await page.route('**/workspace-panel-fixture', route => route.fulfill({
    contentType: 'text/html', body: '<style>body{margin:0}canvas{width:100vw;height:100vh}</style><canvas id="scene"></canvas>',
  }))
  await page.goto(`${origin}/workspace-panel-fixture`)
  const base = new URL('../', import.meta.url).pathname
  const result = await page.evaluate(async base => {
    const { exerciseWorkspacePanel } = await import(`/@fs${base}test/workspace-panel.fixture.js`)
    return exerciseWorkspacePanel()
  }, base)
  assert.equal(result.typed, 'a(X).')
  assert.deepEqual(result.calls, ['run', 'next', 'accept', 'stop', 'close', 'create', 'resolve'])
  assert.ok(result.resultText.includes('Binding59 = value(59)'))
  for (const field of ['scrollable', 'locked', 'sameMesh', 'hidden', 'retired', 'frontFacing',
    'cancelled', 'spatialOpen', 'spatialClosed']) assert.equal(result[field], true, field)
  assert.deepEqual(result.choices, ['rule/2', 'sample/1', 'rule/2'])
  assert.equal(result.choiceLabel, 'rule / 2')
  assert.equal(result.multilineSource, 'p(a).\nq(b).')
  assert.equal(result.newPredicate, 'fresh/2')
  for (const bounds of result.actionBounds) {
    assert.ok(bounds.left >= 0 && bounds.right <= 1280 && bounds.top >= 0 && bounds.bottom <= 1440,
      'all wrapped actions fit inside the texture')
  }
  assert.equal(result.cardsScrollable, true)
  assert.equal(result.sourceRetired, true)
  assert.equal(new Set(result.actionBounds.map(bounds => bounds.top)).size, 2)
  assert.equal(result.oldControlsRetired, true)
  assert.equal(result.lockedChoice, true)
  assert.equal(result.activations, 1)
  assert.deepEqual(result.modes, [true, false])
  return result
}
