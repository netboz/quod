import assert from 'node:assert/strict'

// Run against the UI's Vite server with a browser page supplied by the caller.
// The fixture's meta policy mirrors the production HTTP CSP.
export async function checkMeshBrowser(page, origin) {
  for (const [digest, imageSize] of [
    ['ad1f1cbe8c100fd774e315b629d0bb1082820c9a7abe2a2a999aef846d675064', 2],
    ['2be70465da809e6e29b8b12aae01a568e54cd150e86f35f790e06a61fc82bc04', 2048],
  ]) {
    await page.goto(`${origin}/test/mesh-browser.html?digest=${digest}&imageSize=${imageSize}`)
    const policy = await page.locator('meta[http-equiv="Content-Security-Policy"]')
      .getAttribute('content')
    assert.match(policy, /img-src 'self' data: blob:/)
    const result = await page.evaluate(() => window.meshResult)
    assert.equal(result.occurrences, 2)
    assert.equal(result.sharedTemplate, true)
    assert.equal(result.fetches, 1)
    assert.equal(result.distinctRoots, true)
    assert.equal(result.distinctTransforms, true)
    assert.deepEqual(result.pickedSubjects, ['entity(one)', 'entity(two)'])
    assert.equal(result.importedMetadataCleared, true)
    assert.ok(result.meshes >= 2)
    assert.ok(result.materials >= 1)
    assert.ok(result.embeddedImages >= 1)
    assert.equal(result.textureReady, true)
  }
}
