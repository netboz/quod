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

test('complete source uses one cursor, preserves split UTF-8, and stops at the explicit final chunk', async () => {
  const { readCodeState } = await import('../src/prolog-edit.js')
  const previousFetch = globalThis.fetch
  const whole = new TextEncoder().encode('fact(é).\nrule(X) :- fact(X).\n')
  const paths = []
  let page = 0
  globalThis.fetch = async (url, init) => {
    paths.push([url, init.method])
    if (init.method === 'DELETE') return { ok: true, json: async () => ({ result: 'stopped' }) }
    const part = page++ === 0 ? whole.slice(0, 6) : whole.slice(6)
    const source = compound('source_chunk', [atom(page === 1 ? 'more' : 'done'), binary(part)])
    return { ok: true, json: async () => ({ result: 'solution', cursor: 'snapshot', bindings: [{ Source: renderTerm(source) }] }) }
  }
  try {
    assert.equal(await readCodeState(identity, agent, { target, tools }), new TextDecoder().decode(whole))
    assert.deepEqual(paths, [['/api/goals/cursors', 'POST'], ['/api/goals/cursors/snapshot/next', 'POST'], ['/api/goals/cursors/snapshot', 'DELETE']])
  } finally { globalThis.fetch = previousFetch }
})

test('a lost or exhausted source cursor never publishes a partial ontology', async () => {
  const { readCodeState } = await import('../src/prolog-edit.js')
  const previousFetch = globalThis.fetch
  for (const ending of ['fail', 'lost']) {
    let calls = 0
    globalThis.fetch = async (url, init) => {
      if (init.method === 'DELETE') return { ok: true, json: async () => ({ result: 'stopped' }) }
      if (calls++ === 0) return { ok: true, json: async () => ({ result: 'solution', cursor: 'partial', bindings: [{ Source: 'source_chunk(more,<<"some.">>)' }] }) }
      if (ending === 'lost') throw new TypeError('connection lost')
      return { ok: true, json: async () => ({ result: 'fail' }) }
    }
    try { await assert.rejects(readCodeState(identity, agent, { target, tools })) }
    finally { globalThis.fetch = previousFetch }
  }
})


test('fixed authored source lenses reject other selections before I/O and refuse absent catalogue bindings', async () => {
  const workspace = { target, tools, selection: indicator }
  const other = compound('/', [atom('other'), number(1)])
  const previousFetch = globalThis.fetch
  let calls = 0
  globalThis.fetch = async () => { calls++; return { ok: true, json: async () => ({ result: 'ok', bindings: [{ Predicates: '[]' }] }) } }
  try {
    await assert.rejects(readCodeSource(identity, agent, workspace, other), /authored workspace binding/)
    await assert.rejects(prepareCodeEdit(identity, agent, workspace, null, '', ''), /authored workspace binding/)
    assert.equal(calls, 0)
    await assert.rejects(readCodePredicates(identity, agent, workspace), /no longer available/)
    assert.equal(calls, 1)
  } finally { globalThis.fetch = previousFetch }
})
