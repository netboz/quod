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
  const ready = async () => {
    await page.waitForFunction(() => {
      const field = document.querySelector('textarea[aria-label="Source code"]')
      return field && !field.disabled
    })
    const selection = page.getByRole('combobox').first()
    if (await selection.inputValue() === '') {
      assert.ok((await source.inputValue()).includes('policy(visible).'))
      assert.equal(await source.getAttribute('readonly'), '')
      await selection.selectOption('sample / 1')
      await page.waitForFunction(() => {
        const field = document.querySelector('textarea[aria-label="Source code"]')
        return field && !field.disabled && !field.readOnly
      })
    }
  }
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
    await page.evaluate(() => window.editorFixture.renew('restored-session'))
    await ready()
    assert.equal(await source.inputValue(), draft, 'restoring the same signer preserves the unsaved draft')
    await preview.click()
    await page.waitForFunction(() => Array.from(document.querySelectorAll('button')).some(button => button.textContent === 'Save changes' && !button.disabled))
    await save.click()
    await resolve.waitFor({ state: 'visible' })
    assert.equal(await preview.isDisabled(), true)
    await preview.evaluate(button => button.click())
    let snapshot = await state()
    assert.equal(snapshot.calls.filter(call => call.path === '/api/goals/cursors' && !String(call.goal).includes('prolog_source(')).length, 1)
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
    assert.equal(snapshot.calls.filter(call => call.path === '/api/goals/cursors' && !String(call.goal).includes('prolog_source(')).length, 1)
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

    // An expired idle preview uses the ordinary reasoned-failure response.
    // It keeps the draft editable and does not advance the saved baseline.
    for (const [accept, reason] of [['expired', 'proof_timeout'], ['missing', 'cursor_not_found']]) {
      await configure({ conflict: false, accept })
      const acceptsBefore = (await state()).calls.filter(call => call.path.endsWith('/accept')).length
      await preview.click()
      await page.waitForFunction(() => Array.from(document.querySelectorAll('button')).some(button => button.textContent === 'Save changes' && !button.disabled))
      await save.click()
      await ready()
      assert.ok((await page.getByLabel('Edit result', { exact: true }).textContent()).includes(reason))
      assert.equal(await source.inputValue(), next)
      assert.equal(await save.isDisabled(), true)
      assert.equal(await preview.isDisabled(), false)
      snapshot = await state()
      assert.equal(snapshot.rows.length, 0)
      assert.equal(snapshot.calls.filter(call => call.path.endsWith('/accept')).length, acceptsBefore + 1)
      assert.equal(snapshot.compilerInputs.at(-1).baseline, draft)
    }

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
    const beforeFreshPreview = (await state()).calls.filter(call => call.path === '/api/goals/cursors' && !String(call.goal).includes('prolog_source(')).length
    await source.fill('fresh(next).\n')
    await preview.click()
    await page.waitForFunction(() => Array.from(document.querySelectorAll('button')).some(button => button.textContent === 'Save changes' && !button.disabled))
    snapshot = await state()
    assert.equal(snapshot.calls.filter(call => call.path === '/api/goals/cursors' && !String(call.goal).includes('prolog_source(')).length, beforeFreshPreview + 1)
    assert.equal(snapshot.compilerInputs.at(-1).baseline, fresh)
    assert.equal(snapshot.compilerInputs.at(-1).source, 'fresh(next).\n')
    const recoveredPredicate = await page.getByRole('combobox').first().inputValue()
    await mount({ readOnly: true })
    await value('policy(visible).\n' + 'sample(next).\nfresh(saved).\n')
    assert.equal(await source.getAttribute('readonly'), '')
    assert.equal(await preview.count(), 0)
    assert.equal(await save.count(), 0)
    const spatial = await page.evaluate(() => {
      const model = window.editorFixture.spatial()
      return { sourceKind: model.view.fields.find(field => field.role === 'source').kind,
        source: model.values.source, locked: model.locked }
    })
    assert.equal(spatial.sourceKind, 'bindings', 'read-only spatial source uses the scrollable text component')
    assert.equal(spatial.source, await source.inputValue())
    assert.equal(spatial.locked, false, 'the explicit lens selector stays usable')
    assert.ok((await page.locator('header').textContent()).includes('Genesis:'))
    await page.getByRole('combobox').first().selectOption('sample / 1')
    await value('sample(next).\n')
    assert.equal(await source.getAttribute('readonly'), '')
    await page.getByRole('combobox').first().selectOption('')
    await page.getByRole('button', { name: 'Refresh current state' }).click()
    await value('policy(visible).\nsample(next).\nfresh(saved).\n')

    // Refresh a selected predicate and its authorized representation, without
    // remounting or executing an edit. An unsaved draft is never rebased.
    await page.getByRole('combobox').first().selectOption('sample / 1')
    await value('sample(next).\n')
    const refresh = page.getByRole('button', { name: 'Refresh current state', exact: true })
    assert.equal(await refresh.isEnabled(), true)
    const external = 'sample(external).\n'
    await configure({ source: external, readOnly: false })
    const beforeRefresh = (await state()).calls.filter(call => call.path === '/api/goals/cursors' && !String(call.goal).includes('prolog_source(')).length
    await refresh.click()
    await value(external)
    await ready()
    assert.equal(await source.getAttribute('readonly'), null, 'refresh observes newly granted edit access')
    assert.equal((await state()).calls.filter(call => call.path === '/api/goals/cursors' && !String(call.goal).includes('prolog_source(')).length, beforeRefresh,
      'refresh never probes permission by executing an edit')
    const unsaved = 'sample(unsaved).\n'
    await source.fill(unsaved)
    await configure({ source: 'sample(other_commit).\n', readOnly: true })
    await refresh.click()
    await page.waitForFunction(() => document.querySelector('textarea[aria-label="Source code"]')?.readOnly)
    await value(unsaved)
    assert.equal(await preview.count(), 0, 'refresh observes revoked edit access while preserving the draft')
    await configure({ readOnly: false })
    await refresh.click()
    await ready()
    await preview.click()
    await page.waitForFunction(() => Array.from(document.querySelectorAll('button')).some(button => button.textContent === 'Save changes' && !button.disabled))
    assert.equal((await state()).compilerInputs.at(-1).baseline, external, 'refresh preserves the draft original baseline')
    assert.equal((await state()).compilerInputs.at(-1).source, unsaved)
    await page.getByRole('button', { name: 'Cancel preview', exact: true }).click()
    await ready()
    await configure({ refreshError: 'read access refused' })
    await refresh.click()
    await page.getByRole('alert').getByText('read access refused', { exact: false }).waitFor()
    assert.equal(await source.getAttribute('readonly'), '', 'failed refresh does not advertise stale edit access')
    assert.equal(await source.inputValue(), unsaved)
    await configure({ refreshError: null })
    await refresh.click()
    await ready()
    assert.equal(await source.inputValue(), unsaved)
    await preview.click()
    await page.waitForFunction(() => Array.from(document.querySelectorAll('button')).some(button => button.textContent === 'Save changes' && !button.disabled))
    const beforeRestore = (await state()).calls.filter(call => call.path === '/api/goals/cursors' && !String(call.goal).includes('prolog_source(')).length
    await page.evaluate(() => window.editorFixture.renew('restored-after-preview'))
    await ready()
    assert.equal(await source.inputValue(), unsaved)
    assert.equal(await save.isDisabled(), true, 'restoring retires the old session preview')
    assert.equal((await state()).calls.filter(call => call.path === '/api/goals/cursors' && !String(call.goal).includes('prolog_source(')).length, beforeRestore,
      'restoring never replays a proof or edit')
    snapshot = await state()
    // The real world shell must retain the opened workspace on renewal.
    await mount({ world: true })
    await page.getByRole('region', { name: 'World controls' }).waitFor()
    await page.locator('details.world-advanced summary').click()
    await page.getByLabel('Inspect', { exact: true }).selectOption({ label: 'personal:lobby' })
    await page.getByRole('button', { name: 'View Prolog source', exact: true }).click()
    await page.getByRole('region', { name: 'Focused console' }).getByRole('combobox').first().selectOption('sample / 1')
    await page.waitForFunction(() => {
      const field = document.querySelector('textarea[aria-label="Source code"]')
      return field && !field.disabled && !field.readOnly
    })
    await source.fill('sample(world_restore).\n')
    await page.evaluate(() => window.editorFixture.renew('world-renewed'))
    await value('sample(world_restore).\n')
    await page.getByRole('region', { name: 'Focused console' }).waitFor()
    assert.equal(await source.isVisible(), true, 'world retains the source panel for the same signer and actor')
    return { cursorSubmissions: snapshot.calls.filter(call => call.path === '/api/goals/cursors' && !String(call.goal).includes('prolog_source(')).length,
      outcomeLookups: snapshot.calls.filter(call => call.path === '/api/goals/outcomes').length,
      compilerInputs: snapshot.compilerInputs, editedCards, recoveredPredicate, pendingRows: snapshot.rows.length }
  } catch (error) {
    error.message += '\nFixture world state: ' + await page.locator('body').innerText()
    throw error
  } finally { await page.evaluate(() => window.editorFixture?.dispose()) }
}
