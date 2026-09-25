import assert from 'node:assert/strict'
import test from 'node:test'
import {
  createKeyProvider,
  localKeyMatches,
  saveVerifiedLocalKeyProvider,
  exportEncryptedKeyProvider,
  importEncryptedKeyProvider,
  b64url,
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

test('encrypted identity carries exact per-network account references', async () => {
  const provider = await createKeyProvider()
  provider.accounts = [{ network: b64url(new Uint8Array(32).fill(7)),
    namespace: 'human:portable', anchor: b64url(new Uint8Array(32).fill(19)), instanceText: 'me.' }]
  const bundle = await exportEncryptedKeyProvider(provider, 'correct horse battery staple')
  assert.equal(bundle.includes('human:portable'), false)
  const imported = await importEncryptedKeyProvider(bundle, 'correct horse battery staple')
  assert.deepEqual(imported.publicKey, provider.publicKey)
  assert.equal(imported.accounts.length, 1)
  for (const [key, value] of Object.entries(provider.accounts[0])) {
    assert.equal(imported.accounts[0][key], value)
  }
  const request = new Uint8Array([1, 2, 3])
  assert.equal(await crypto.subtle.verify('Ed25519', provider.keyPair.publicKey,
    await imported.sign(request), request), true)
})
