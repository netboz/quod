import { strict as assert } from 'node:assert'
import { test } from 'node:test'
import { anchoredGoal, readReference, readGuiView, proofForm, codeForm, singleBinding } from '../src/world.js'
import { atom, compound, variable } from '../src/prolog-term.js'

const FORM = 'form(<<"Console">>,[editor(goal,<<"Goal">>),bindings(results,<<"Bindings">>),button(run,<<"Run">>),button(next,<<"Next">>),button(accept,<<"Accept">>),button(stop,<<"Stop">>),button(resolve,<<"Check saved outcome">>)])'

test('a device projection binds the exact selected ontology before reading content', () => {
  const anchor = new Uint8Array(32).fill(255)
  const goal = anchoredGoal({ namespace: 'lobby', anchor }, compound('lobby_view', [atom('playing'), variable('Scene')]))
  assert.ok(goal.startsWith('<<"lobby">> :: (current_ontology_identity(<<"lobby">>,<<"'))
  assert.ok(goal.includes('\\xff\\'.repeat(32)))
  assert.ok(goal.endsWith('lobby_view(playing,Scene)).'))
  assert.throws(() => anchoredGoal({ namespace: 'lobby', anchor: new Uint8Array(31) }, atom('true')))
})

test('lobby references preserve identity bytes and refuse display abbreviations', () => {
  const ref = readReference('ontology_ref(<<"lobby">>,<<"' + '\\x0\\'.repeat(32) + '">>)')
  assert.equal(ref.namespace, 'lobby')
  assert.deepEqual(ref.anchor, new Uint8Array(32))
  assert.throws(() => readReference('ontology_ref(<<"lobby">>,kp_1234)'))
})

test('the reusable proof form requires each supported semantic role exactly once', () => {
  assert.deepEqual(proofForm(readGuiView(FORM)), {
    title: 'Console', goal: 'Goal', results: 'Bindings', run: 'Run', next: 'Next', accept: 'Accept', stop: 'Stop', resolve: 'Check saved outcome',
  })
  for (const bad of [FORM.replace('button(stop,<<"Stop">>)', 'button(run,<<"Stop">>)'),
    FORM.replace(',button(stop,<<"Stop">>)', ''), FORM.replace('editor(goal,', 'button(goal,'),
    FORM.replace('button(run,', 'button(execute_javascript,')]) {
    assert.throws(() => proofForm(readGuiView(bad)))
  }
})

test('forms describe semantic components independently of their workspace name', () => {
  const view = readGuiView('form(<<"Code">>,[choice(predicate,<<"Predicate">>),input(new_predicate,<<"New predicate">>),editor(source,<<"Source">>),bindings(results,<<"Result">>),button(run,<<"Preview">>),button(accept,<<"Save">>),button(stop,<<"Cancel">>),button(create,<<"Add predicate">>),button(resolve,<<"Check saved outcome">>)])')
  assert.equal(codeForm(view).source, 'Source')
  assert.throws(() => proofForm(view), /cannot render/)
  const future = readGuiView('form(<<"Future">>,[hologram(model,<<"Model">>)])')
  assert.throws(() => codeForm(future), /cannot render hologram/)
})

test('a partial or ambiguous projection is not a successful view', () => {
  assert.equal(singleBinding({ result: 'ok', bindings: [{ View: FORM }] }, 'View'), FORM)
  for (const reply of [{ result: 'fail' }, { result: 'pending' },
    { result: 'ok', bindings: [{ View: FORM }, { View: FORM }] }, { result: 'ok', bindings: [{}] }]) {
    assert.throws(() => singleBinding(reply, 'View'))
  }
})
