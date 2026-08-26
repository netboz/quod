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
    const first = saveAgentReference({
      namespace: 'agent:alice', anchor: 'a'.repeat(43),
      instanceText: 'human_user(alice).',
    })
    const second = saveAgentReference({
      namespace: 'agent:robot', anchor: 'b'.repeat(43),
      instanceText: 'fipa_agent(robot_1).',
    })
    assert.equal(activeAgentReference().id, second.id)
    selectAgentReference(first.id)
    assert.equal(activeAgentReference().id, first.id)
    assert.equal(agentReferences().length, 2)
    removeAgentReference(first.id)
    assert.equal(activeAgentReference().id, second.id)
  })
})

test('malformed storage input is rejected before signing', () => {
  withStorage(() => {
    assert.throws(
      () => saveAgentReference({ namespace: '', anchor: 'a'.repeat(43), instanceText: 'x.' }),
      /invalid agent reference/,
    )
    assert.throws(
      () => saveAgentReference({ namespace: 'agent:x', anchor: 'bad', instanceText: 'x.' }),
      /invalid agent reference/,
    )
  })
})

test('agent-reference namespaces use the shared 255-byte protocol limit', () => {
  withStorage(() => {
    const namespace255 = `${'é'.repeat(127)}a`
    assert.equal(new TextEncoder().encode(namespace255).length, 255)
    assert.equal(saveAgentReference({
      namespace: namespace255,
      anchor: 'a'.repeat(43),
      instanceText: 'human_user(alice).',
    }).namespace, namespace255)
    assert.throws(
      () => saveAgentReference({
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
  }
  try { run() } finally { globalThis.localStorage = previous }
}
