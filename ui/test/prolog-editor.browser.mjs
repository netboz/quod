import assert from 'node:assert/strict'

// Real components and browser persistence; HTTP simulation is explicit in the
// fixture and complements the signed, real-namespace EUnit integration.
export async function checkPrologEditor(page, origin) {
  await page.route('**/prolog-editor-fixture', route => route.fulfill({
    contentType: 'text/html', body: '<div id="fixture"></div>',
  }))
  await page.goto(`${origin}/prolog-editor-fixture`)
  const path = new URL('./prolog-editor.fixture.tsx', import.meta.url).pathname
  await page.evaluate(async path => {
    const refresh = await import('/@react-refresh')
    refresh.default.injectIntoGlobalHook(window)
    window.$RefreshReg$ = () => {}
    window.$RefreshSig$ = () => type => type
    window.__vite_plugin_react_preamble_installed__ = true
    const { createEditorFixture } = await import(`/@fs${path}`)
    window.editorFixture = await createEditorFixture()
    window.editorFixture.mount()
  }, path)
  const source = page.getByLabel('Source code', { exact: true })
  const preview = page.getByRole('button', { name: 'Preview changes', exact: true })
  const save = page.getByRole('button', { name: 'Save changes', exact: true })
  const resolve = page.getByRole('button', { name: 'Check saved outcome', exact: true })
  const ready = () => page.waitForFunction(() => {
    const field = document.querySelector('textarea[aria-label="Source code"]')
    return field && !field.disabled
  })
  const value = expected => page.waitForFunction(expected =>
    document.querySelector('textarea[aria-label="Source code"]')?.value === expected, expected)
  const configure = options => page.evaluate(options => window.editorFixture.configure(options), options)
  const mount = options => page.evaluate(options => window.editorFixture.mount(options), options)
  const state = () => page.evaluate(async () => ({
    calls: window.editorFixture.calls, compilerInputs: window.editorFixture.compilerInputs,
    rows: await window.editorFixture.rows(),
  }))
  try {
    await ready()
    assert.equal(await source.inputValue(), 'sample(before).\n')
    const draft = 'sample(after).\n'
    await source.fill(draft)
    await preview.click()
    await page.waitForFunction(() => Array.from(document.querySelectorAll('button')).some(button => button.textContent === 'Save changes' && !button.disabled))
    await save.click()
    await resolve.waitFor({ state: 'visible' })
    assert.equal(await preview.isDisabled(), true)
    await preview.evaluate(button => button.click())
    let snapshot = await state()
    assert.equal(snapshot.calls.filter(call => call.path === '/api/goals/cursors').length, 1)
    assert.equal(snapshot.rows.length, 1)
    assert.equal(snapshot.rows[0].context.source, draft)
    assert.equal(snapshot.rows[0].context.baseline, 'sample(before).\n')

    // Same namespace alone grants no draft/recovery association. Each of key,
    // exact target anchor and actor instance must match the stored operation.
    for (const options of [{ key: 'other' }, { targetAnchor: 8 }, { actor: 'other' }, { agentAnchor: 10 }]) {
      await mount(options)
      await ready()
      assert.equal(await source.inputValue(), 'sample(before).\n')
      assert.equal(await resolve.count(), 0)
      assert.equal((await state()).rows.length, 1)
    }
    await mount({ session: 'renewed-session' })
    await value(draft)
    await resolve.waitFor({ state: 'visible' })
    assert.equal(await preview.isDisabled(), true)
    await resolve.click()
    await page.getByLabel('Edit result', { exact: true }).getByText('The saved operation has no final result yet.', { exact: false }).waitFor()
    assert.equal(await preview.isDisabled(), true)
    assert.equal((await state()).rows.length, 1)
    await configure({ terminal: true })
    await resolve.click()
    await ready()
    const result = await page.getByLabel('Edit result', { exact: true }).textContent()
    assert.ok(result.includes('committed'))
    assert.ok(!result.includes('height #0'))
    snapshot = await state()
    assert.equal(snapshot.rows.length, 0)
    assert.equal(snapshot.calls.filter(call => call.path === '/api/goals/cursors').length, 1)
    assert.equal(snapshot.calls.filter(call => call.path === '/api/goals/outcomes').length, 2)

    // Positive lookup advances the baseline. A later conflict preserves this
    // draft and never turns the old unknown operation into a fresh submission.
    const next = 'sample(next).\n'
    await source.fill(next)
    await configure({ conflict: true })
    await preview.click()
    await ready()
    assert.ok((await page.getByLabel('Edit result', { exact: true }).textContent()).includes('edit_conflict'))
    assert.equal(await source.inputValue(), next)
    snapshot = await state()
    assert.equal(snapshot.compilerInputs.at(-1).baseline, draft)
    assert.equal(snapshot.compilerInputs.at(-1).source, next)
    assert.equal(await save.isDisabled(), true)

    // A positive pending response follows the same persisted recovery path.
    await configure({ conflict: false, accept: 'pending', terminal: false })
    await preview.click()
    await page.waitForFunction(() => Array.from(document.querySelectorAll('button')).some(button => button.textContent === 'Save changes' && !button.disabled))
    await save.click()
    await resolve.waitFor({ state: 'visible' })
    assert.equal(await preview.isDisabled(), true)
    await mount({})
    await value(next)
    await resolve.waitFor({ state: 'visible' })
    snapshot = await state()
    assert.equal(snapshot.rows.length, 1)
    assert.equal(snapshot.rows[0].context.source, next)
    assert.equal(snapshot.rows[0].context.baseline, draft)
    assert.ok(snapshot.rows[0].outcome_ref)
    assert.ok(snapshot.calls.filter(call => call.body.request).every(call => call.signatureVerified))
    await configure({ terminal: true })
    await resolve.click()
    await ready()
    const cardSource = '% Kept until a structural edit\nsample(one).\nsample(two).\n'
    await source.fill(cardSource)
    await page.getByLabel('Code layout', { exact: true }).selectOption('cards')
    await page.getByLabel('Clause head', { exact: true }).waitFor()
    await page.waitForFunction(() => !document.querySelector('input[aria-label="Clause head"]').disabled)
    assert.equal(await page.getByLabel('Clause head', { exact: true }).inputValue(), 'sample(one)')
    await page.getByLabel('Code layout', { exact: true }).selectOption('text')
    assert.equal(await source.inputValue(), cardSource, 'changing view alone preserves the exact source draft')
    await page.getByLabel('Code layout', { exact: true }).selectOption('cards')
    await page.waitForFunction(() => {
      const head = document.querySelector('input[aria-label="Clause head"]')
      return head && !head.disabled
    })
    await page.getByLabel('Clause head', { exact: true }).fill('sample(changed)')
    await page.getByLabel('Clause body', { exact: true }).fill('allowed(changed)')
    await page.getByRole('button', { name: 'Move down', exact: true }).click()
    await page.getByLabel('Code layout', { exact: true }).selectOption('text')
    const editedCards = 'sample(two).\nsample(changed) :- allowed(changed).\n'
    assert.equal(await source.inputValue(), editedCards)
    snapshot = await state()
    assert.equal(snapshot.calls.filter(call => String(call.goal).includes('prolog_clauses(')).length, 2,
      'only explicit card switches parse source, never head/body keystrokes')
    // Recover a newly authored predicate while its initial catalogue request
    // still holds an older answer. Finishing that read cannot erase the draft.
    await page.getByLabel('New predicate', { exact: true }).fill('fresh/1')
    await page.getByRole('button', { name: 'Add predicate', exact: true }).click()
    await ready()
    assert.equal(await source.inputValue(), '')
    const fresh = 'fresh(saved).\n'
    await source.fill(fresh)
    await configure({ accept: 'lost', terminal: false })
    await preview.click()
    await page.waitForFunction(() => Array.from(document.querySelectorAll('button')).some(button => button.textContent === 'Save changes' && !button.disabled))
    await save.click()
    await resolve.waitFor({ state: 'visible' })
    await configure({ holdCatalogue: true, terminal: true })
    await mount({})
    await page.waitForFunction(() => window.editorFixture.heldCatalogues() === 1)
    await value(fresh)
    await resolve.click()
    await page.waitForFunction(async () => (await window.editorFixture.rows()).length === 0)
    await page.evaluate(() => window.editorFixture.releaseCatalogue())
    await ready()
    assert.equal(await page.getByRole('combobox').first().inputValue(), 'fresh / 1',
      'a late catalogue response preserves the recovered predicate selection')
    assert.equal(await source.inputValue(), fresh)
    const beforeFreshPreview = (await state()).calls.filter(call => call.path === '/api/goals/cursors').length
    await source.fill('fresh(next).\n')
    await preview.click()
    await page.waitForFunction(() => Array.from(document.querySelectorAll('button')).some(button => button.textContent === 'Save changes' && !button.disabled))
    snapshot = await state()
    assert.equal(snapshot.calls.filter(call => call.path === '/api/goals/cursors').length, beforeFreshPreview + 1)
    assert.equal(snapshot.compilerInputs.at(-1).baseline, fresh)
    assert.equal(snapshot.compilerInputs.at(-1).source, 'fresh(next).\n')
    return { cursorSubmissions: snapshot.calls.filter(call => call.path === '/api/goals/cursors').length,
      outcomeLookups: snapshot.calls.filter(call => call.path === '/api/goals/outcomes').length,
      compilerInputs: snapshot.compilerInputs, editedCards, recoveredPredicate: await page.getByRole('combobox').first().inputValue(), pendingRows: snapshot.rows.length }
  } finally { await page.evaluate(() => window.editorFixture?.dispose()) }
}
