import assert from 'node:assert/strict'
import test from 'node:test'
import {
  atom,
  binary,
  compound,
  formatClause,
  formatTerm,
  goalText,
  list,
  number,
  renderTerm,
  string,
  variable,
} from '../src/prolog-term.js'
import { readTerm } from '../src/prolog-read.js'
import { readFileSync } from 'node:fs'
import { PROLOG_TERM_LIMITS } from '../src/protocol-limits.js'
import { encodeGoalRequest } from '../src/signed-client.js'

test('generic terms render ordinary inspectable Prolog text', () => {
  assert.equal(
    goalText(compound('inspect', [
      atom("owner's value"),
      string('line\n"quoted"'),
      number(42),
      variable('Result'),
      list([atom('one'), atom('two')], variable('Tail')),
    ])),
    "inspect('owner\\'s value',\"line\\n\\\"quoted\\\"\",42,Result,[one,two|Tail]).",
  )
})

test('namespace atoms use the same quoting rule as every other atom', () => {
  assert.equal(renderTerm(atom('quod:benchmark_target')), "'quod:benchmark_target'")
})

test('builder text and direct text produce byte-identical signed requests', () => {
  const built = goalText(compound('saved', [atom('ok')]))
  const direct = 'saved(ok).'
  assert.equal(built, direct)
  const fields = {
    networkIdentity: u256(1),
    signingPublicKey: u256(2),
    operationId: u256(3),
    agentNamespace: 'quod:builder-test',
    agentAnchor: u256(4),
    agentInstanceText: 'human_user(alice).',
    mode: 'execute',
    notAfterMs: 1_800_000_000_000,
  }
  assert.deepEqual(
    encodeGoalRequest({ ...fields, goal: built }),
    encodeGoalRequest({ ...fields, goal: direct }),
  )
})

test('binary terms use explicit Erlang notation and preserve every byte', () => {
  assert.equal(
    goalText(compound('admit', [binary(Uint8Array.from([0x00, 0x22, 0x5c, 0x7f, 0xff]))])),
    ['admit(<<"', '\\x00\\', '\\"', '\\\\', '\\x7f\\', '\\xff\\', '">>).'].join(''),
  )
})

test('builders reject malformed variables, numbers, and structures', () => {
  assert.throws(() => goalText(variable('lowercase')), /variable/)
  assert.throws(() => goalText(number(Number.NaN)), /number/)
  assert.throws(() => goalText(number(Number.MAX_SAFE_INTEGER + 1)), /integer/)
  assert.throws(() => goalText(compound('empty', [])), /compound/)
  assert.throws(() => goalText(list([], variable('Tail'))), /list/)
})

function u256(lastByte) {
  const value = new Uint8Array(32)
  value[31] = lastByte
  return value
}

test('console scope construction handles terminators, quoted periods and trailing comments', async () => {
  const { scopedGoal } = await import('../src/prolog-term.js')
  assert.equal(scopedGoal('a', 'a', 'member(X, [a, b])'), 'member(X, [a, b])\n.')
  assert.equal(scopedGoal('a', 'a', 'true. % retained'), 'true % retained\n.')
  assert.equal(scopedGoal('a', 'b', 'true. /* retained */'), 'b :: (\ntrue /* retained */\n).')
  assert.equal(scopedGoal('a', 'b', 'write(<<"a.%/*">>).'), 'b :: (\nwrite(<<"a.%/*">>)\n).')
  assert.equal(scopedGoal('a', 'b', "'a\\x27\\b'."), "b :: (\n'a\\x27\\b'\n).")
  for (const bad of ['', ' % no goal', '/* open', "'open"]) assert.throws(() => scopedGoal('a', 'b', bad))
})

test('canonical code terms retain variable sharing within one clause only', () => {
  const clause = readTerm("':-'(same(V0,V0),pair(_,_,_Named,_Named))")
  const [head, body] = clause.args
  assert.strictEqual(head.args[0], head.args[1])
  assert.notStrictEqual(body.args[0], body.args[1])
  assert.strictEqual(body.args[2], body.args[3])
  assert.notStrictEqual(head.args[0], readTerm('V0'))
  assert.equal(formatClause(clause), 'same(V0, V0) :- pair(_, _, _Named, _Named).')
})

test('canonical partial lists preserve their tail instead of dropping it', () => {
  const term = readTerm('pair([first,V0|V1],V1)')
  assert.strictEqual(term.args[0].tail, term.args[1])
  assert.equal(formatTerm(term), 'pair([first, V0 | V1], V1)')
  assert.equal(formatTerm(readTerm('[first|last]')), '[first | last]')
  for (const bad of ['[|V0]', '[a|]', '[a|b,c]', '[a|b|c]']) {
    assert.throws(() => readTerm(bad))
  }
})

test('code numbers keep float identity and integers beyond JavaScript precision', () => {
  assert.equal(readTerm('9007199254740993').value, 9007199254740993n)
  assert.equal(formatTerm(readTerm('9007199254740993')), '9007199254740993')
  for (const literal of ['1.0', '-0.0', '-1.25', '1.0e-7', '1.0e+100']) {
    assert.equal(formatTerm(readTerm(literal)), literal.startsWith('-') ? `(${literal})` : literal)
  }
  assert.equal(formatTerm(number(1e-7)), '1.0e-7')
  // The existing request writer's spelling remains unchanged.
  assert.equal(renderTerm(number(1e-7)), '1e-7')
  for (const bad of ['1.0e309', '1.0e', '1.2.3', '12x']) {
    assert.throws(() => readTerm(bad))
  }
  assert.throws(() => formatTerm({ type: 'number', value: 2, literal: '1.0' }))
})

test('readable source preserves associativity, controls, cut and scoped goals', () => {
  const cases = [
    ["':-'(choose(V0),','(candidate(V0),'!'))", 'choose(V0) :- candidate(V0), !.'],
    ["'::'(':'(quod,world),','(read(V0),write(V0)))", 'quod : world :: (read(V0), write(V0)).'],
    ["is(V0,'+'(1,'*'(2,'^'(3,4))))", 'V0 is 1 + 2 * 3 ^ 4.'],
    ["'-'(a,'-'(b,c))", 'a - (b - c).'],
    ["'-'('-'(a,b),c)", 'a - b - c.'],
    ["'^'('^'(a,b),c)", '(a ^ b) ^ c.'],
    ["'^'(a,'^'(b,c))", 'a ^ b ^ c.'],
    ["';'('->'(','(a,b),c),d)", 'a, b -> c ; d.'],
    ["','(';'(a,b),c)", '(a ; b), c.'],
    ["call(','(a,b))", 'call((a, b)).'],
    ["'\\\\+'(','(a,b))", '\\+ (a, b).'],
    ["'*'(a)", 'a * .'],
  ]
  for (const [canonical, source] of cases) {
    assert.equal(formatClause(readTerm(canonical)), source)
  }
})

test('quoted code data retains literal dots, comment markers, quotes and bytes', () => {
  const term = compound('values', [
    atom('a.b%/*c*/'), atom("owner's value"), atom(''),
    binary(Uint8Array.from([0, 34, 92, 46, 37, 255])),
  ])
  const source = formatClause(term)
  assert.equal(source,
    "values('a.b%/*c*/', 'owner\\'s value', '', <<\"\\x00\\\\\"\\\\.%\\xff\\\">>).")
  // The result reader consumes only canonical functional notation, not source.
  assert.deepEqual(readTerm(source.slice(0, -1)), term)
  for (const source of ['a, b', 'a :- b', 'a % comment', '/* comment */ a']) {
    assert.throws(() => readTerm(source))
  }
})

test('current code source distinguishes numeric negatives from unary expressions', () => {
  assert.equal(formatClause(compound('p', [number(-3), number(-0), number(-9007199254740993n)])), 'p((-3), (-0.0), (-9007199254740993)).')
  assert.equal(formatClause(compound('p', [compound('-', [number(3)])])), 'p(- 3).')
  assert.equal(formatClause(compound('p', [compound('**', [number(-3), number(2)])])), 'p((-3) ** 2).')
  assert.equal(renderTerm(number(-0)), '-0.0')
})

test('the result reader shares server depth without private list or rendered-text ceilings', () => {
  const header = readFileSync(new URL('../../include/quod_term_limits.hrl', import.meta.url), 'utf8')
  assert.equal(PROLOG_TERM_LIMITS.depth, Number(/QUOD_MAX_TERM_DEPTH, (\d+)/.exec(header)[1]))
  const nested = depth => 'f('.repeat(depth) + 'leaf' + ')'.repeat(depth)
  assert.doesNotThrow(() => readTerm(nested(PROLOG_TERM_LIMITS.depth)))
  assert.throws(() => readTerm(nested(PROLOG_TERM_LIMITS.depth + 1)), /deeply nested/)
  assert.equal(readTerm('[' + Array(1200).fill('0').join(',') + ']').items.length, 1200)
  const bytes = readTerm('<<"' + '\\xff\\'.repeat(14000) + '">>')
  assert.equal(bytes.value.length, 14000)
})
