import assert from 'node:assert/strict'
import test from 'node:test'
import {
  activeAgentReference,
  agentReferences,
  removeAgentReference,
  saveAgentReference,
  selectAgentReference,
} from '../src/agent-references.js'

test('agent references are stored and selected independently of the signing key', () => {
  withStorage(() => {
    const network = 'n'.repeat(43)
    const first = saveAgentReference({
      network,
      namespace: 'agent:alice', anchor: 'a'.repeat(43),
      instanceText: 'human_user(alice).',
    })
    const second = saveAgentReference({
      network,
      namespace: 'agent:robot', anchor: 'b'.repeat(43),
      instanceText: 'fipa_agent(robot_1).',
    })
    assert.equal(activeAgentReference(network).id, second.id)
    selectAgentReference(first.id, network)
    assert.equal(activeAgentReference(network).id, first.id)
    assert.equal(agentReferences(network).length, 2)
    removeAgentReference(first.id)
    assert.equal(activeAgentReference(network).id, second.id)
  })
})

test('agent references and active selection are isolated by root network', () => {
  withStorage(() => {
    const oldNetwork = 'o'.repeat(43)
    const newNetwork = 'n'.repeat(43)
    const old = saveAgentReference({ network: oldNetwork,
      namespace: 'human:old', anchor: 'a'.repeat(43), instanceText: 'human_user(me).' })
    const current = saveAgentReference({ network: newNetwork,
      namespace: 'human:new', anchor: 'b'.repeat(43), instanceText: 'human_user(me).' })
    assert.deepEqual(agentReferences(oldNetwork), [old])
    assert.deepEqual(agentReferences(newNetwork), [current])
    assert.equal(activeAgentReference(oldNetwork).id, old.id)
    assert.equal(activeAgentReference(newNetwork).id, current.id)
    assert.throws(() => selectAgentReference(old.id, newNetwork), /unknown agent reference/)
  })
})

test('legacy global references are not loaded into a root network', () => {
  withStorage(values => {
    values.set('quod.agent-references.v1', JSON.stringify({ active: 'legacy', rows: [{
      id: 'legacy', namespace: 'human:old', anchor: 'a'.repeat(43),
      instanceText: 'human_user(me).',
    }] }))
    assert.deepEqual(agentReferences('n'.repeat(43)), [])
    assert.equal(activeAgentReference('n'.repeat(43)), null)
    assert.equal(values.has('quod.agent-references.v1'), false)
  })
})

test('removing an active reference chooses a replacement from the same network', () => {
  withStorage(() => {
    const firstNetwork = 'a'.repeat(43)
    const otherNetwork = 'b'.repeat(43)
    const first = saveAgentReference({ network: firstNetwork,
      namespace: 'human:first', anchor: 'a'.repeat(43), instanceText: 'human_user(me).' })
    const other = saveAgentReference({ network: otherNetwork,
      namespace: 'human:other', anchor: 'b'.repeat(43), instanceText: 'human_user(me).' })
    const replacement = saveAgentReference({ network: firstNetwork,
      namespace: 'human:replacement', anchor: 'c'.repeat(43), instanceText: 'human_user(me).' })
    selectAgentReference(first.id, firstNetwork)
    removeAgentReference(first.id)
    assert.equal(activeAgentReference(firstNetwork).id, replacement.id)
    assert.equal(activeAgentReference(otherNetwork).id, other.id)
  })
})

test('malformed storage input is rejected before signing', () => {
  withStorage(() => {
    assert.throws(
      () => saveAgentReference({ network: 'n'.repeat(43),
        namespace: '', anchor: 'a'.repeat(43), instanceText: 'x.' }),
      /invalid agent reference/,
    )
    assert.throws(
      () => saveAgentReference({ network: 'n'.repeat(43),
        namespace: 'agent:x', anchor: 'bad', instanceText: 'x.' }),
      /invalid agent reference/,
    )
    assert.throws(
      () => saveAgentReference({ network: 'bad',
        namespace: 'agent:x', anchor: 'a'.repeat(43), instanceText: 'x.' }),
      /invalid network identity/,
    )
  })
})

test('agent-reference namespaces use the shared 255-byte protocol limit', () => {
  withStorage(() => {
    const namespace255 = `${'é'.repeat(127)}a`
    assert.equal(new TextEncoder().encode(namespace255).length, 255)
    assert.equal(saveAgentReference({
      network: 'n'.repeat(43),
      namespace: namespace255,
      anchor: 'a'.repeat(43),
      instanceText: 'human_user(alice).',
    }).namespace, namespace255)
    assert.throws(
      () => saveAgentReference({
        network: 'n'.repeat(43),
        namespace: `${namespace255}b`,
        anchor: 'a'.repeat(43),
        instanceText: 'human_user(alice).',
      }),
      /invalid agent reference/,
    )
  })
})

function withStorage(run) {
  const previous = globalThis.localStorage
  const values = new Map()
  globalThis.localStorage = {
    getItem: key => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value),
    removeItem: key => values.delete(key),
  }
  try { run(values) } finally { globalThis.localStorage = previous }
}
