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
  return checkWorkspacePanelResult(result)
}

// The MCP browser runs the same fixture and records its real control/render
// results. Both browser drivers verify them through these identical checks.
export function checkWorkspacePanelResult(result) {
  assert.equal(result.typed, 'a(X).')
  assert.equal(result.initialBackground, 'rgba(25,43,50,0.78)')
  assert.equal(result.translucentBackground, 'rgba(25,43,50,0.6)')
  assert.equal(result.opaqueBackground, 'rgba(25,43,50,1)')
  assert.equal(result.steppedOpacity, 0.95)
  assert.equal(result.opaqueControls, true)
  assert.equal(result.steppedGain, '7')
  assert.equal(result.clampedGain, '11')
  assert.equal(result.invalidGridIgnored, true)
  assert.equal(result.numericEntry, '3')
  assert.equal(result.rotatedAngle, '20')
  assert.equal(result.steppedAngle, '15')
  assert.equal(result.frozenNumeric, true)
  assert.equal(result.lockedNumeric, true)
  assert.equal(result.semanticSelection, 'mode(run)')
  assert.equal(result.commonText, 'Spectrum 2')
  for (const bounds of result.numericBounds) {
    assert.ok(bounds.left >= 0 && bounds.right <= 1280 && bounds.top >= 0 && bounds.bottom <= 1440,
      'composed numeric controls fit inside the texture')
  }
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
