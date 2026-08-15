import assert from 'node:assert/strict'
import test from 'node:test'
import {
  atom,
  compound,
  goalText,
  list,
  number,
  string,
  variable,
} from '../src/prolog-term.js'
import { encodeGoalRequest } from '../src/signed-client.js'

test('generic terms render ordinary inspectable V1 Prolog text', () => {
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

test('builder text and direct text produce byte-identical signed requests', () => {
  const built = goalText(compound('saved', [atom('ok')]))
  const direct = 'saved(ok).'
  assert.equal(built, direct)
  const fields = {
    networkIdentity: u256(1),
    userPublicKey: u256(2),
    operationId: u256(3),
    namespace: 'quod:builder-test',
    anchor: u256(4),
    mode: 'execute',
    notAfterMs: 1_800_000_000_000,
  }
  assert.deepEqual(
    encodeGoalRequest({ ...fields, goal: built }),
    encodeGoalRequest({ ...fields, goal: direct }),
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
