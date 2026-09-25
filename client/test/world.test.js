import { strict as assert } from 'node:assert'
import { test } from 'node:test'
import { anchoredGoal, readReference, readProofView, singleBinding } from '../src/world.js'
import { atom, compound, variable } from '../src/prolog-term.js'

const FORM = 'form(<<"Console">>,[editor(goal,<<"Goal">>),bindings(results,<<"Bindings">>),button(run,<<"Run">>),button(next,<<"Next">>),button(accept,<<"Accept">>),button(stop,<<"Stop">>)])'

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
  assert.deepEqual(readProofView(FORM), {
    title: 'Console', goal: 'Goal', results: 'Bindings', run: 'Run', next: 'Next', accept: 'Accept', stop: 'Stop',
  })
  for (const bad of [FORM.replace('button(stop,<<"Stop">>)', 'button(run,<<"Stop">>)'),
    FORM.replace(',button(stop,<<"Stop">>)', ''), FORM.replace('editor(goal,', 'button(goal,'),
    FORM.replace('button(run,', 'button(execute_javascript,')]) {
    assert.throws(() => readProofView(bad))
  }
})

test('a partial or ambiguous projection is not a successful view', () => {
  assert.equal(singleBinding({ result: 'ok', bindings: [{ View: FORM }] }, 'View'), FORM)
  for (const reply of [{ result: 'fail' }, { result: 'pending' },
    { result: 'ok', bindings: [{ View: FORM }, { View: FORM }] }, { result: 'ok', bindings: [{}] }]) {
    assert.throws(() => singleBinding(reply, 'View'))
  }
})
