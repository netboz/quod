import { strict as assert } from 'node:assert'
import { test } from 'node:test'
import { anchoredGoal, readReference, readGuiView, proofForm, codeForm, singleBinding, GoalFailure } from '../src/world.js'
import { atom, compound, variable } from '../src/prolog-term.js'

const component = (role, kind, label, children = [], properties = []) =>
  `component(${role},${kind},[property(label,<<"${label}">>)${properties.map(p => ',' + p).join('')}],[${children.join(',')}])`
const form = (title, fields) => component('workspace', 'form', title, fields)
const FORM = form('Console', [component('goal', 'editor', 'Goal'), component('results', 'bindings', 'Bindings'),
  ...['run', 'next', 'accept', 'stop'].map(role => component(role, 'button', role[0].toUpperCase() + role.slice(1))),
  component('resolve', 'button', 'Check saved outcome')])

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
  for (const bad of [FORM.replace('component(stop,', 'component(run,'),
    FORM.replace(',' + component('stop', 'button', 'Stop'), ''), FORM.replace('component(goal,editor,', 'component(goal,button,'),
    FORM.replace('component(run,', 'component(execute_javascript,')]) {
    assert.throws(() => proofForm(readGuiView(bad)))
  }
})

test('forms describe semantic components independently of their workspace name', () => {
  const view = readGuiView(form('Code', [component('predicate', 'catalogue_selection', 'Predicate'),
    component('new_predicate', 'text_box', 'New predicate'), component('source', 'editor', 'Source'),
    component('results', 'bindings', 'Result'), ...['run', 'accept', 'stop', 'create', 'resolve']
      .map(role => component(role, 'button', role))]))
  assert.equal(codeForm(view).source, 'Source')
  assert.equal(codeForm(view).editable, true)
  assert.deepEqual(codeForm(readGuiView(form('Public source', [component('predicate', 'catalogue_selection', 'Predicate'), component('source', 'editor', 'Source')]))), {
    title: 'Public source', predicate: 'Predicate', source: 'Source', editable: false,
  })
  assert.throws(() => proofForm(view), /cannot render/)
  assert.throws(() => readGuiView(form('Future', [component('model', 'hologram', 'Model')])), /unsupported GUI component/)
})

test('portable components preserve nested identities, typed options and exact ranges', () => {
  const leaf = component('setting(2)', 'rotary_knob', 'Angle', [], [
    'property(range,range(-30,30,5))', 'property(unit,degrees)', 'property(readonly,true)',
  ])
  const selection = component('mode', 'selection', 'Mode', [], [
    'property(options,[option(mode(review),<<"Review">>),option(mode(run),<<"Run">>)])',
  ])
  const source = form('Device', [component('controls', 'container', 'Controls', [leaf, selection], [
    'property(layout,row)', 'property(enabled,false)',
  ])])
  const view = readGuiView(source)
  assert.equal(view.fields[0].enabled, false)
  assert.equal(view.fields[0].layout, 'row')
  const [knob, choice] = view.fields[0].children
  assert.equal(knob.role, 'setting(2)')
  assert.equal(knob.readonly, true)
  assert.deepEqual(knob.range, { min: -30, max: 30, step: 5 })
  assert.deepEqual(choice.options, [{ value: 'mode(review)', label: 'Review' }, { value: 'mode(run)', label: 'Run' }])
  for (const bad of [source.replace('setting(2)', 'controls'), source.replace('setting(2)', 'setting(X)'),
    source.replace('range(-30,30,5)', 'range(-30,30,0)'), source.replace('range(-30,30,5)', 'range(0,9007199254740992,1)'),
    source.replace('range(-30,30,5)', 'range(-30,30,5.0)'), source.replace('mode(run)', 'mode(review)'),
    source.replace('property(layout,row)', 'property(layout,row),property(layout,column)'),
    source.replace('property(layout,row)', 'property(executable,do_something)'),
    source.replace('property(enabled,false)', 'property(enabled,maybe)'),
    source.replace('container', 'button'), source.replace('form', 'container')]) {
    assert.throws(() => readGuiView(bad))
  }
  assert.throws(() => readGuiView('form(<<"Old">>,[])'))
  assert.throws(() => readGuiView(form('Missing catalogue', [component('mode', 'selection', 'Mode')])))
  for (const [kind, property] of [['text_box', 'range(0,10,1)'], ['button', 'range(0,10,1)'],
    ['container', 'range(0,10,1)'], ['bindings', 'range(0,10,1)']]) {
    assert.throws(() => readGuiView(form('Misplaced', [component('field', kind, 'Field', [], [`property(range,${property})`])])))
  }
})

test('a partial or ambiguous projection is not a successful view', () => {
  assert.equal(singleBinding({ result: 'ok', bindings: [{ View: FORM }] }, 'View'), FORM)
  for (const reply of [{ result: 'fail' }, { result: 'pending' },
    { result: 'ok', bindings: [{ View: FORM }, { View: FORM }] }, { result: 'ok', bindings: [{}] }]) {
    assert.throws(() => singleBinding(reply, 'View'))
  }
})

test('projection failures preserve explicit access denials without inventing them for other failures', () => {
  const reasons = ['<<"quod:modelling">>::ontology_eidolons(unbound)', 'not_allowed(<<"quod:modelling">>)']
  assert.throws(() => singleBinding({ result: 'fail', reasons }, 'Choices'), error =>
    error instanceof GoalFailure && error.accessDenied && error.reasons === reasons &&
    error.message === 'This account is not allowed to make this query.')
  for (const reasons of [undefined, [], ['predicate_failed(ontology_eidolons)'],
    ['error(not_allowed(<<"quod:modelling">>))'], ['<<"not_allowed(target)">>'], ['malformed(']]) {
    assert.throws(() => singleBinding({ result: 'fail', reasons }, 'Choices'), error =>
      error instanceof GoalFailure && !error.accessDenied && error.message === 'The query returned no answer.')
  }
  assert.throws(() => singleBinding({ result: 'pending' }, 'Choices'), error => !(error instanceof GoalFailure))
  assert.throws(() => singleBinding({ result: 'ok', bindings: [] }, 'Choices'), error => !(error instanceof GoalFailure))
})
