import test from 'node:test'
import assert from 'node:assert/strict'
import { driveInput, teleportInput, pushInput } from '../src/locomotion.js'
import { formatClause } from '../src/prolog-term.js'

test('signed motion quantization encodes integer zero, including negative sub-milli values', () => {
  assert.equal(formatClause(driveInput([-0, -0.0009, 0.0009], [-0.0001, -0, 0])),
    'drive(vector(0, 0, 0), angular(0, 0, 0)).')
  assert.equal(formatClause(teleportInput([-0, -0.0009, 0.0009])), 'teleport(vector(0, 0, 0)).')
  assert.equal(formatClause(pushInput('2', '1', [-0, -0.0009, 0.0009])),
    'push(body(2, 1), vector(0, 0, 0)).')
})

test('motion quantization keeps signed truncation and invalid input rejection', () => {
  assert.equal(formatClause(driveInput([1.2349, -1.2349, 0], [0, -0.0019, 0.0019])),
    'drive(vector(1234, (-1234), 0), angular(0, (-1), 1)).')
  assert.equal(formatClause(teleportInput([1.2349, -1.2349, 0])),
    'teleport(vector(1234, (-1234), 0)).')
  assert.equal(formatClause(pushInput('2', '1', [1.2349, -1.2349, 0])),
    'push(body(2, 1), vector(1234, (-1234), 0)).')
  for (const invalid of [NaN, Infinity, -Infinity]) {
    assert.throws(() => driveInput([invalid, 0, 0]))
    assert.throws(() => driveInput([0, 0, 0], [invalid, 0, 0]))
    assert.throws(() => teleportInput([invalid, 0, 0]))
    assert.throws(() => pushInput('2', '1', [invalid, 0, 0]))
  }
})

test('landing uses exact canonical millimetres beyond the browser integer range', () => {
  const origin = 2n ** 100n
  const term = teleportInput([1.25, -2.5, 0], [origin, -origin, origin])
  const vector = term.args[0].args
  assert.deepEqual(vector.map(n => n.value), [origin + 1250n, -origin - 2500n, origin])
})
