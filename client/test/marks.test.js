import { strict as assert } from 'node:assert'
import { test } from 'node:test'

import { readTerm, readList } from '../src/prolog-read.js'
import { readMarks } from '../src/marks.js'
import { diagnosisGoal, viewGoal } from '../src/lens.js'

// Exactly what a signed read of quod:lens returns for the authored lens: one
// verdict mark and the components behind it, as quod_explorer_http renders a
// binding. Keeping the fixture in the renderer's own spelling is the point —
// the reader has to cope with what the node actually sends.
const REPLY =
  '[mark(<<"m0">>, <<"box">>, [f(<<"width">>, 400), f(<<"height">>, 1500), ' +
  'f(<<"depth">>, 400)], transform(0, 750, 0, 0, 0, 0), ' +
  'material(<<"#F9C80E">>, <<"matte">>), label(<<"NOASSERTION">>, <<"above">>), ' +
  'depicts(<<"quod:licence">>, ships(<<"quod">>, <<"NOASSERTION">>))), ' +
  'mark(<<"m1">>, <<"box">>, [f(<<"width">>, 400), f(<<"height">>, 300), ' +
  'f(<<"depth">>, 400)], transform(600, 150, -900, 0, 0, 0), ' +
  'material(<<"#698F3F">>, <<"matte">>), label(<<"cowboy">>, <<"above">>), ' +
  'depicts(<<"quod:licence">>, component(<<"quod">>, <<"cowboy">>)))]'

test('a reply becomes drawable marks', () => {
  const marks = readMarks(REPLY)
  assert.equal(marks.length, 2)
  const [verdict, part] = marks
  assert.equal(verdict.id, 'm0')
  assert.equal(verdict.kind, 'box')
  assert.deepEqual(verdict.size, { width: 400, height: 1500, depth: 400 })
  assert.deepEqual(verdict.transform, { x: 0, y: 750, z: 0, rx: 0, ry: 0, rz: 0 })
  assert.deepEqual(verdict.material, { colour: '#F9C80E', finish: 'matte' })
  assert.deepEqual(verdict.label, { text: 'NOASSERTION', placement: 'above' })
  assert.equal(verdict.depicts.ontology, 'quod:licence')
  // the subject stays a term: selection resolves through it, not a mesh name
  assert.equal(verdict.depicts.entity.functor, 'ships')
  assert.equal(part.depicts.entity.functor, 'component')
  assert.equal(part.depicts.entity.args[1].value, 'cowboy')
})

test('a mark may show nothing and carry no label', () => {
  const [mark] = readMarks(
    '[mark(<<"m0">>, <<"sphere">>, [f(<<"diameter">>, 900)], ' +
    'transform(0, 0, 0, 0, 0, 0), material(<<"#C14953">>, <<"emissive">>), ' +
    'unlabelled, depicts_nothing)]')
  assert.equal(mark.label, null)
  assert.equal(mark.depicts, null)
  assert.deepEqual(mark.size, { diameter: 900 })
})

test('several marks may depict one entity', () => {
  const twice = REPLY.replace('<<"m1">>', '<<"m2">>')
    .replace('ships(<<"quod">>, <<"NOASSERTION">>)',
             'component(<<"quod">>, <<"cowboy">>)')
  const marks = readMarks(twice)
  const subjects = marks.map(mark => mark.depicts.entity.args[1].value)
  assert.deepEqual(subjects, ['cowboy', 'cowboy'])
  assert.deepEqual(marks.map(mark => mark.id), ['m0', 'm2'])
})

test('an unreadable descriptor fails closed', () => {
  const cases = {
    'unknown kind': REPLY.replace('<<"box">>', '<<"torus">>'),
    'unknown field': REPLY.replace('<<"width">>', '<<"girth">>'),
    'reordered fields': REPLY.replace(
      '[f(<<"width">>, 400), f(<<"height">>, 1500), f(<<"depth">>, 400)]',
      '[f(<<"height">>, 1500), f(<<"width">>, 400), f(<<"depth">>, 400)]'),
    'a colour that is not one': REPLY.replace('<<"#F9C80E">>', '<<"gold">>'),
    'an unknown finish': REPLY.replace('<<"matte">>', '<<"velvet">>'),
    'an unknown placement': REPLY.replace('<<"above">>', '<<"left">>'),
    'a fractional dimension': REPLY.replace('400)', '400.5)'),
    'a repeated mark identity': REPLY.replace('<<"m1">>', '<<"m0">>'),
    'a mark with a part missing':
      REPLY.replace(', label(<<"NOASSERTION">>, <<"above">>)', ''),
  }
  for (const [what, text] of Object.entries(cases)) {
    assert.throws(() => readMarks(text), undefined, `${what} was accepted`)
  }
})

// The reply renderer turns any 32-byte binary into a key fingerprint and
// shortens a binary it cannot print. Neither carries the value any more, so
// neither may be drawn as though it did.
test('a binary that did not survive the reply is refused', () => {
  assert.throws(() => readMarks(REPLY.replace('<<"cowboy">>', 'kp_545337d5')))
  assert.throws(() => readMarks(REPLY.replace('<<"cowboy">>', '<<0x0badc0de…>>')))
})

test('the reader accepts what the renderer writes and nothing more', () => {
  assert.deepEqual(readTerm('[]'), { type: 'list', items: [] })
  assert.equal(readTerm('-1800').value, -1800)
  assert.equal(readTerm('unlabelled').value, 'unlabelled')
  assert.equal(readTerm("'quod:licence'").value, 'quod:licence')
  assert.equal(readTerm('<<"a \\"quoted\\" name">>').value, 'a "quoted" name')
  assert.equal(readList('[a, b, c]').length, 3)
  for (const bad of ['[a, b', 'f(a', 'f(a,)', '[a|b]', '<<"open', 'a b', '', '??']) {
    assert.throws(() => readTerm(bad), undefined, `${bad} was accepted`)
  }
})

test('the reader is bounded', () => {
  assert.throws(() => readTerm('f('.repeat(40) + 'a' + ')'.repeat(40)),
                /deeply nested/)
  assert.throws(() => readTerm('x'.repeat(70000)), /too large/)
})

test('the lens is asked by its flat binary name, with the dot the grammar needs',
     () => {
       assert.equal(viewGoal('work_licences', ['quod']),
                    '<<"quod:lens">> :: (view(<<"work_licences">>,[<<"quod">>],Marks)).')
       assert.equal(diagnosisGoal('work_licences', ['quod']),
                    '<<"quod:lens">> :: (diagnosis(<<"work_licences">>,[<<"quod">>],Unmet)).')
     })
