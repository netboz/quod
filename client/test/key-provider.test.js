import assert from 'node:assert/strict'
import test from 'node:test'
import {
  createKeyProvider,
  localKeyMatches,
  saveVerifiedLocalKeyProvider,
} from '../src/key-provider.js'

test('verified browser backup contains the exact active identity', async () => {
  const previousStorage = Object.getOwnPropertyDescriptor(globalThis, 'localStorage')
  const values = new Map()
  Object.defineProperty(globalThis, 'localStorage', {
    configurable: true,
    value: {
      getItem: key => values.get(key) ?? null,
      setItem: (key, value) => values.set(key, value),
    },
  })
  try {
    const provider = await createKeyProvider()
    await saveVerifiedLocalKeyProvider(provider, 'correct horse battery staple')
    assert.equal(localKeyMatches(provider), true)
    assert.equal(localKeyMatches(await createKeyProvider()), false)
  } finally {
    restoreProperty('localStorage', previousStorage)
  }
})

test('verified browser backup fails when storage silently discards it', async () => {
  const previousStorage = Object.getOwnPropertyDescriptor(globalThis, 'localStorage')
  Object.defineProperty(globalThis, 'localStorage', {
    configurable: true,
    value: {
      getItem: () => null,
      setItem: () => undefined,
    },
  })
  try {
    const provider = await createKeyProvider()
    await assert.rejects(
      saveVerifiedLocalKeyProvider(provider, 'correct horse battery staple'),
      /did not keep the encrypted key/,
    )
  } finally {
    restoreProperty('localStorage', previousStorage)
  }
})

function restoreProperty(name, descriptor) {
  if (descriptor) Object.defineProperty(globalThis, name, descriptor)
  else delete globalThis[name]
}
