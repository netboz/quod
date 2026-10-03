import assert from 'node:assert/strict'
import test from 'node:test'
import { readFileSync } from 'node:fs'
import { readCodePredicates, readCodeSource, prepareCodeEdit, predicateIndicator, clausesSource } from '../src/prolog-edit.js'
import { binary, compound, number, atom, renderTerm } from '../src/prolog-term.js'

const bytes = text => binary(new TextEncoder().encode(text))
const target = { namespace: 'personal:lobby', anchor: new Uint8Array(32).fill(7) }
const tools = { namespace: 'quod:prolog', anchor: new Uint8Array(32).fill(8) }
const indicator = compound('/', [atom('sample'), number(1)])
const agent = { namespace: 'human:owner', anchor: new Uint8Array(32).fill(9), instanceText: 'human_user(owner).' }
const identity = {
  networkId: new Uint8Array(32).fill(1),
  session: { session_id: 'session', expires_ms: Date.now() + 60_000 },
  provider: { publicKey: new Uint8Array(32).fill(2), sign: async () => new Uint8Array(64).buffer },
}

test('the code adapter only reads exact tools and target references; preparing an edit does not submit it', async () => {
  const previousFetch = globalThis.fetch
  const source = "sample(X) :- member(X, [first, 'a.b'])."
  const returnedGoal = `'::'(${renderTerm(bytes(target.namespace))},','(current_ontology_identity(${renderTerm(bytes(target.namespace))},${renderTerm(binary(target.anchor))}),transaction(assertz(':-'(sample(V17),member(V17,[new]))))))`
  const answers = [
    { Predicates: "['/'(sample,1)]" },
    { Source: renderTerm(bytes(source)) },
    { Edit: returnedGoal },
  ]
  let calls = 0
  globalThis.fetch = async (url, init) => {
    assert.equal(url, '/api/goals/read')
    const request = new TextDecoder().decode(Buffer.from(JSON.parse(init.body).request, 'base64url'))
    assert.ok(request.includes(`current_ontology_identity(${renderTerm(bytes(tools.namespace))},${renderTerm(binary(tools.anchor))})`))
    assert.ok(request.includes(`ontology_ref(${renderTerm(bytes(target.namespace))},${renderTerm(binary(target.anchor))})`))
    const bindings = answers[calls++]
    return { ok: true, json: async () => ({ result: 'ok', bindings: [bindings] }) }
  }
  try {
    assert.deepEqual(await readCodePredicates(identity, agent, { target, tools }), [indicator])
    assert.equal(await readCodeSource(identity, agent, { target, tools }, indicator), source)
    const goal = await prepareCodeEdit(identity, agent, { target, tools }, indicator, source, 'sample(new).')
    assert.ok(goal.startsWith('<<"personal:lobby">> :: (current_ontology_identity('))
    assert.ok(goal.includes('assertz((sample(V17) :- member(V17, [new])))'))
    assert.ok(goal.endsWith('.'))
    assert.equal(calls, 3)
  } finally { globalThis.fetch = previousFetch }
})

test('predicate selection and clause cards remain ordinary source data', () => {
  assert.deepEqual(predicateIndicator('sample/1'), indicator)
  assert.deepEqual(predicateIndicator('sample / 1'), indicator)
  assert.equal(renderTerm(predicateIndicator("'with space'/0")), "'/'('with space',0)")
  for (const value of ['p', 'p/-1', 'P/1', 'p/1.5', 'p(X)/2']) assert.throws(() => predicateIndicator(value))
  assert.equal(clausesSource([{ head: 'p(X)', body: 'q(X), !' }, { head: 'p(fallback)', body: '' }]), 'p(X) :- q(X), !.\np(fallback).\n')
  assert.equal(clausesSource([]), '')
})

// Captured from the real quod_prolog compiler and admitted by the server's
// current grammar and client-result codec; this is functional wire notation.
test('a real thirty-clause compiled edit crosses the shared result reader', async () => {
  const wire = readFileSync(new URL('./fixtures/prolog-compiled-edit-30.txt', import.meta.url), 'utf8')
  const previousFetch = globalThis.fetch
  globalThis.fetch = async url => {
    assert.equal(url, '/api/goals/read')
    return { ok: true, json: async () => ({ result: 'ok', bindings: [{ Edit: wire }] }) }
  }
  try {
    const anchor = new Uint8Array(32)
    anchor[31] = 71
    const workspace = { tools, target: { namespace: 'test:edited', anchor } }
    const source = Array.from({ length: 30 }, (_, index) => `sample(${index + 1}).`).join('\n')
    const goal = await prepareCodeEdit(identity, agent, workspace, indicator, '', source)
    assert.equal((goal.match(/assertz\(/g) ?? []).length, 30)
    assert.ok(goal.startsWith('<<"test:edited">> :: (current_ontology_identity('))
    assert.ok(goal.includes('transaction('))
    assert.ok(goal.includes("'$quod_predicate_source'"))
    assert.ok(!goal.includes("'$quod_authored_clauses'"))
  } finally { globalThis.fetch = previousFetch }
})
