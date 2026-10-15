import assert from 'node:assert/strict'

// Desktop interaction with the production component, signing and durable local
// storage. Explicit HTTP fixture responses complement real-owner HTTPS tests.
export async function checkOntologyTextEditor(page, origin, screenshotPath) {
  await page.route('**/ontology-text-fixture', route => route.fulfill({ contentType: 'text/html', body: '<div id="fixture"></div>' }))
  await page.goto(`${origin}/ontology-text-fixture`)
  const path = new URL('./prolog-editor.fixture.tsx', import.meta.url).pathname
  const setup = async () => page.evaluate(async path => {
    const refresh = await import('/@react-refresh')
    refresh.default.injectIntoGlobalHook(window)
    window.$RefreshReg$ = () => {}
    window.$RefreshSig$ = () => type => type
    window.__vite_plugin_react_preamble_installed__ = true
    const { createEditorFixture } = await import(`/@fs${path}`)
    window.editorFixture = await createEditorFixture()
    window.editorFixture.mount()
  }, path)
  await setup()
  const source = page.getByLabel('Source code', { exact: true })
  const preview = page.getByRole('button', { name: 'Preview changes', exact: true })
  const save = page.getByRole('button', { name: 'Save changes', exact: true })
  const ready = () => page.waitForFunction(() => {
    const area = document.querySelector('textarea[aria-label="Source code"]')
    return area && !area.disabled
  })
  const configure = options => page.evaluate(options => window.editorFixture.configure(options), options)
  const mount = options => page.evaluate(options => window.editorFixture.mount(options), options)
  try {
    await ready()
    const baseline = await source.inputValue()
    assert.equal(baseline, 'policy(visible).\nsample(before).\n')
    assert.equal(await source.getAttribute('readonly'), null)
    const draft = '% Authored names stay in the draft\nsample(Customer) :-\n    registry:members::allowed(Customer).\nother(<<"literal">>).\n'
    await source.fill(draft)
    assert.equal(await page.locator('.prolog-rule').textContent(), 'sample')
    assert.equal(await page.locator('.prolog-variable').first().textContent(), 'Customer')
    assert.equal(await page.locator('.prolog-namespace').first().textContent(), 'registry')
    assert.equal(await page.locator('.prolog-qualified').textContent(), 'allowed')
    if (screenshotPath) await page.screenshot({ path: screenshotPath, fullPage: true })
    await source.focus()
    await page.keyboard.press('Control+f')
    await page.getByRole('searchbox').fill('Customer')
    await page.getByRole('button', { name: 'Find next', exact: true }).click()
    assert.equal(await source.evaluate(area => area.value.slice(area.selectionStart, area.selectionEnd)), 'Customer')
    await source.evaluate(area => { area.focus(); area.setSelectionRange(0, area.value.length) })
    await page.getByRole('button', { name: 'Indent', exact: true }).click()
    assert.equal(await source.inputValue(), draft.slice(0, -1).replace(/^/gm, '    ') + '\n')
    await page.getByRole('button', { name: 'Outdent', exact: true }).click()
    assert.equal(await source.inputValue(), draft)
    await source.press('Control+]')
    assert.equal(await source.inputValue(), draft.slice(0, -1).replace(/^/gm, '    ') + '\n')
    await source.press('Control+[')
    assert.equal(await source.inputValue(), draft)
    await source.fill('sample(Customer) :-')
    await source.press('Control+End')
    await source.press('Enter')
    assert.equal(await source.inputValue(), 'sample(Customer) :-\n    ')
    await source.press('Control+z')
    assert.equal(await source.inputValue(), 'sample(Customer) :-')
    await source.fill(draft)
    await source.press('Control+End')
    await source.press('Enter')
    await source.press('Control+z')
    assert.equal(await source.inputValue(), draft, 'native indentation keeps undo')
    await page.getByText('Review local changes against opened baseline', { exact: true }).click()
    assert.equal(await page.getByRole('heading', { name: 'Opened baseline', exact: true }).locator('..').locator('pre').textContent(), baseline)
    // A real reload restores the same IndexedDB signer and exact local draft.
    await page.reload()
    await setup()
    await ready()
    assert.equal(await source.inputValue(), draft)
    for (const options of [{ key: 'other' }, { targetAnchor: 8 }, { actor: 'other' }, { agentAnchor: 10 }]) {
      await mount(options); await ready(); assert.equal(await source.inputValue(), baseline)
    }
    await mount({}); await ready(); assert.equal(await source.inputValue(), draft)
    await configure({ compileError: 'syntax_error(invalid_syntax)' })
    await preview.click(); await ready()
    await page.getByRole('alert').getByText('syntax_error', { exact: false }).waitFor()
    assert.equal(await source.inputValue(), draft)
    await configure({ compileError: null, accept: 'lost', terminal: false })
    await preview.click(); await save.waitFor()
    await page.waitForFunction(() => [...document.querySelectorAll('button')].some(b => b.textContent === 'Save changes' && !b.disabled))
    await save.click()
    const resolve = page.getByRole('button', { name: 'Check saved outcome', exact: true })
    await resolve.waitFor()
    assert.equal(await preview.isDisabled(), true)
    await mount({ session: 'reconnected' }); await resolve.waitFor()
    assert.equal(await source.inputValue(), draft)
    await configure({ terminal: true }); await resolve.click(); await ready()
    const state = await page.evaluate(() => ({ calls: window.editorFixture.calls, inputs: window.editorFixture.compilerInputs }))
    assert.equal(state.calls.filter(call => call.path.endsWith('/accept')).length, 1)
    assert.equal(state.calls.filter(call => call.path === '/api/goals/cursors' && !String(call.goal).includes('prolog_source(')).length, 1)
    assert.equal(state.inputs[0].baseline, baseline)
    assert.equal(state.inputs[0].source, draft)
    const second = draft + 'additional(change).\n'
    await source.fill(second)
    await configure({ conflict: true }); await preview.click(); await ready()
    assert.equal(await source.inputValue(), second)
    assert.ok((await page.getByLabel('Edit result', { exact: true }).textContent()).includes('edit_conflict'))
    await page.getByRole('button', { name: 'Discard draft and reload', exact: true }).click()
    await ready()
    assert.equal(await source.inputValue(), draft, 'explicit discard loads the current committed text')
    await source.fill(second)
    await configure({ readOnly: true })
    await page.getByRole('button', { name: 'Refresh current state', exact: true }).click()
    await page.waitForFunction(() => document.querySelector('textarea[aria-label="Source code"]')?.readOnly)
    assert.equal(await source.inputValue(), second)
    assert.equal(await preview.count(), 0)
    return { passed: true, fullBaseline: baseline, acceptRequests: 1, lostReplyResubmissions: 0,
      checks: ['complete-source editing', 'highlighting', 'search', 'indentation undo', 'exact-identity draft retention', 'parse rejection', 'lost reply recovery', 'stale conflict', 'revocation'] }
  } catch (error) { error.message += '\n' + await page.locator('body').innerText(); throw error }
  finally { await page.evaluate(() => window.editorFixture?.dispose()) }
}
