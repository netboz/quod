import { composedView } from './gui-composition.js'
import { strict as assert } from 'node:assert'
import { test } from 'node:test'
import { anchoredGoal, readReference, readGuiView, readGuiQuestionForm, readGuiQuestionReferences, readGuiQuestionStatus,
  guiQuestionSubmission, guiQuestionCancellation, proofForm, codeForm, singleBinding, GoalFailure } from '../src/world.js'
import { atom, compound, variable, renderTerm } from '../src/prolog-term.js'
import { readTerm } from '../src/prolog-read.js'

const component = (role, kind, label, children = [], properties = []) =>
  `component(${role},${kind},[property(label,<<"${label}">>)${properties.map(p => ',' + p).join('')}],[${children.join(',')}])`
const form = (title, fields) => component('workspace', 'form', title, fields)
const FORM = form('Console', [component('goal', 'editor', 'Goal'), component('results', 'bindings', 'Bindings'),
  ...['run', 'next', 'accept', 'stop'].map(role => component(role, 'button', role[0].toUpperCase() + role.slice(1))),
  component('resolve', 'button', 'Check saved outcome')])

test('question forms preserve accepted revisions and typed defaults across schema changes', () => {
  const digest = char => `<<"${char.repeat(32)}">>`
  const tree = form('Question', [component('name', 'text_box', 'Name'),
    component('mode', 'selection', 'Mode', [], ['property(options,[option(mode(review),<<"Review">>)])']),
    component('level', 'slider', 'Level', [], ['property(range,range(0,100,5))']),
    component('apply', 'button', 'Apply')])
  const projection = `question_form(form_ref(<<"app">>,${digest('a')},workspace),` +
    `agent_instance_ref(<<"responder">>,${digest('b')},handler),${digest('r')},awaiting,` +
    `form_view(${digest('s')},${tree},${digest('v')},` +
    '[field(name,<<"">>),field(mode,mode(review)),field(level,50)],apply))'
  const decoded = readGuiQuestionForm(projection)
  assert.notEqual(decoded.openedRevision, decoded.revision)
  assert.equal(decoded.interaction, 'stale')
  assert.equal(readGuiQuestionForm(projection.replace(digest('s'), digest('r'))).interaction, 'editable')
  assert.deepEqual({ ...decoded.values }, { name: '', mode: 'mode(review)', level: '50' })
  assert.equal(decoded.submit, 'apply')
  assert.equal(decoded.source.form, 'workspace')
  assert.equal(decoded.responsible.instanceText, 'handler.')
  assert.equal(decoded.view.title, 'Question')
  const submitted = projection.replace(',awaiting,', ',submitted(original_operation,old_button,[field(retired,42)]),')
  assert.equal(readGuiQuestionForm(submitted).state.functor, 'submitted')
  assert.equal(readGuiQuestionForm(submitted).interaction, 'submitted')
  assert.equal(readGuiQuestionForm(submitted.replace(digest('s'), digest('r'))).interaction, 'submitted')
  for (const bad of [projection.replace(digest('a'), '<<"short">>'),
    projection.replace('component(workspace,', 'component(other_form,'),
    projection.replace('field(name,<<"">>)', 'field(name,not_text)'),
    projection.replace('field(mode,mode(review))', 'field(mode,mode(unknown))'),
    projection.replace('field(level,50)', 'field(level,9007199254740992)'),
    projection.replace('field(level,50)', 'field(level,50.0)'),
    projection.replace(',field(level,50)', ''),
    projection.replace('field(level,50)', 'field(name,<<"">>)'),
    projection.replace(',apply))', ',unknown_button))'),
    projection.replace(',awaiting,', ',applied,')]) assert.throws(() => readGuiQuestionForm(bad))
})

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


test('HUD references are exact, ground and unique', () => {
  const row = `question_ref(<<"responder">>,<<"${'a'.repeat(32)}">>,question(7))`
  const [ref] = readGuiQuestionReferences(`[${row}]`)
  assert.equal(ref.namespace, 'responder')
  assert.equal(ref.anchor.length, 32)
  assert.equal(renderTerm(ref.question), 'question(7)')
  assert.match(guiQuestionCancellation(ref), /gui_cancel\(question\(7\)\)/)
  for (const bad of [`[${row},${row}]`, `[${row}|Tail]`, row,
    `[${row.replace('question(7)', 'Question')}]`,
    `[${row.replace('a'.repeat(32), 'short')}]`]) {
    assert.throws(() => readGuiQuestionReferences(bad))
  }
})

test('draft submission carries fields as data and keeps the accepted revision', () => {
  const reference = { namespace: 'responder', anchor: new Uint8Array(32), question: compound('question', [atom('one')]) }
  const fields = [component('name', 'text_box', 'Name'),
    component('mode', 'selection', 'Mode', [], ['property(options,[option(mode(review),<<"Review">>)])']),
    component('level', 'slider', 'Level', [], ['property(range,range(0,100,5))']),
    component('apply', 'button', 'Apply')]
  const digest = `<<"${'r'.repeat(32)}">>`
  const projection = `question_form(form_ref(<<"app">>,${digest},workspace),` +
    `agent_instance_ref(<<"responder">>,${digest},handler),${digest},awaiting,` +
    `form_view(${digest},${form('Question', fields)},${digest},` +
    '[field(name,<<"">>),field(mode,mode(review)),field(level,50)],apply))'
  const view = readGuiQuestionForm(projection)
  const draft = { name: 'Text ), assertz(injected).', mode: 'mode(review)', level: '75' }
  const goal = guiQuestionSubmission(reference, view, draft)
  assert.match(goal, /gui_submit\(question\(one\),/)
  // Parse the actual gui_submit term back: punctuation in text is inert bytes.
  const start = goal.indexOf('gui_submit(')
  const submit = readTerm(goal.slice(start, -2))
  assert.equal(submit.functor, 'gui_submit')
  assert.equal(new TextDecoder().decode(submit.args[1].value), 'r'.repeat(32))
  assert.equal(new TextDecoder().decode(submit.args[3].items[0].args[1].value), draft.name)
  assert.equal(renderTerm(submit.args[3].items[1].args[1]), 'mode(review)')
  assert.equal(submit.args[3].items[2].args[1].value, 75)
  for (const changed of [{ ...draft, level: '76' }, { ...draft, level: '1e2' },
    { ...draft, mode: 'assertz(injected)' }, { ...draft, extra: 'ignored' }, { name: 'Missing' }]) {
    assert.throws(() => guiQuestionSubmission(reference, view, changed))
  }
  for (const interaction of ['stale', 'submitted']) {
    assert.throws(() => guiQuestionSubmission(reference, { ...view, interaction }, draft))
  }
})

test('status uses signed reads and never turns unknown into cancellation permission', async () => {
  const identity = { networkId: new Uint8Array(32),
    provider: { publicKey: new Uint8Array(32), sign: async () => new Uint8Array(64).buffer },
    session: { session_id: 'session', expires_ms: Date.now() + 60000 } }
  const agent = { namespace: 'human', anchor: new Uint8Array(32), instanceText: 'person.' }
  const reference = { namespace: 'responder', anchor: new Uint8Array(32), question: atom('question') }
  const calls = []
  let reply = { result: 'ok', bindings: [{ Status: 'expired' }] }
  const options = { post: async (url, body) => { calls.push([url, body]); return reply } }
  assert.equal(await readGuiQuestionStatus(identity, agent, reference, options), 'expired')
  for (const unavailable of [{ result: 'error', error: 'proof_unavailable' },
    { result: 'ok', bindings: [{ Status: 'unknown' }] },
    { result: 'fail', reasons: ['not_allowed'] }]) {
    reply = unavailable
    await assert.rejects(readGuiQuestionStatus(identity, agent, reference, options))
  }
  assert.equal(calls.length, 4)
  assert(calls.every(([url, body]) => url === '/api/goals/read' && body.request && body.signature))
})


test('input variants preserve typed drafts and reject malformed selections', () => {
  const fields = [component('notes', 'text_area', 'Notes', [], ['property(max_bytes,12)']),
    component('count', 'number_input', 'Count', [], ['property(range,range(-2,8,3))']),
    component('agree', 'checkbox', 'Agree', [], ['property(required,true)']),
    component('power', 'toggle', 'Power'),
    component('mode', 'radio_group', 'Mode', [], ['property(options,[option(mode(a),<<"A">>),option(mode(b),<<"B">>)])']),
    component('items', 'selectable_list', 'Items', [], ['property(multiple,true)', 'property(required,true)',
      'property(options,[option(item(a),<<"A">>),option(item(b),<<"B">>)])']),
    component('apply', 'button', 'Apply')]
  const digest = `<<"${'r'.repeat(32)}">>`
  const projection = `question_form(form_ref(<<"app">>,${digest},workspace),` +
    `agent_instance_ref(<<"responder">>,${digest},handler),${digest},awaiting,` +
    `form_view(${digest},${component('workspace', 'form', 'Inputs', fields)},${digest},` +
    '[field(notes,<<"">>),field(count,-2),field(agree,false),field(power,false),field(mode,mode(a)),field(items,[])],apply))'
  const form = readGuiQuestionForm(projection)
  assert.deepEqual({ ...form.values }, { notes: '', count: '-2', agree: 'false', power: 'false', mode: 'mode(a)', items: '[]' })
  const draft = { notes: 'one\ntwo', count: '7', agree: 'true', power: 'false', mode: 'mode(b)', items: '[item(b),item(a)]' }
  const reference = { namespace: 'responder', anchor: new Uint8Array(32), question: atom('question') }
  const goal = guiQuestionSubmission(reference, form, draft)
  const terms = readTerm(goal.slice(goal.indexOf('gui_submit('), -2)).args[3].items
  assert.equal(new TextDecoder().decode(terms[0].args[1].value), draft.notes)
  assert.equal(terms[1].args[1].value, 7)
  assert.equal(renderTerm(terms[2].args[1]), 'true')
  assert.equal(renderTerm(terms[5].args[1]), '[item(b),item(a)]')
  for (const change of [{ notes: 'é'.repeat(7) }, { count: '8' }, { agree: 'false' }, { power: '0' },
    { items: '[]' }, { items: '[item(a),item(a)]' }, { items: '[item(z)]' },
    { items: '[item(a)|Tail]' }, { items: 'assertz(injected)' }]) {
    assert.throws(() => guiQuestionSubmission(reference, form, { ...draft, ...change }))
  }
  for (const change of ['field(power,0)', 'field(items,[item(z)])', 'field(items,[item(a),item(a)])']) {
    assert.throws(() => readGuiQuestionForm(projection.replace(change.startsWith('field(power') ? 'field(power,false)' : 'field(items,[])', change)))
  }
})


test('composition and display keep the input-only submission contract', () => {
  const view = composedView()
  const reference = { namespace: 'responder', anchor: new Uint8Array(32), question: atom('question') }
  const form = { interaction: 'editable', view, openedRevision: 'A'.repeat(43), submit: 'apply' }
  const goal = guiQuestionSubmission(reference, form, { left: 'L', right: 'R' })
  const fields = readTerm(goal.slice(goal.indexOf('gui_submit('), -2)).args[3].items
  assert.deepEqual(fields.map(field => renderTerm(field.args[0])), ['left', 'right'])
  assert.throws(() => guiQuestionSubmission(reference, form, { left: 'L', right: 'R', loading: '65' }))
  for (const property of ['property(percent,101)', 'property(percent,-1)']) {
    assert.throws(() => readGuiView(component('workspace', 'form', 'Progress', [
      component('loading', 'progress', 'Loading', [], [property])])) )
  }
})

test('tables, images and transient containers stay inside the common descriptor contract', async () => {
  const { remainingView } = await import('./gui-remaining.js')
  const view = remainingView('a'.repeat(64))
  const rows = view.fields.find(field => field.role === 'rows')
  assert.deepEqual(rows.headings, ['Channel', 'Value'])
  assert.deepEqual(rows.options.at(-1), { value: 'row(11)', label: 'Channel 11 · 110', cells: ['Channel 11', '110'] })
  assert.equal(view.fields.find(field => field.role === 'picture').image, 'a'.repeat(64))
  assert.equal(view.fields.find(field => field.role === 'settings').kind, 'dialog')
  assert.throws(() => remainingView('bad'), /SHA-256/)
  const table = cells => form('Table', [component('rows', 'table', 'Rows', [], [
    'property(headings,[<<"A">>,<<"B">>])', `property(options,[option(a,${cells})])`])])
  assert.throws(() => readGuiView(table('[<<"one">>]')), /column count/)
  assert.throws(() => readGuiView(table('<<"not cells">>')), /table cells/)
})
