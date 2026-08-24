const STORAGE_KEY = 'quod.agent-signing-key.v1'
const IDENTITY_DATABASE = 'quod.identity.v1'
const IDENTITY_STORE = 'identity'
const IDENTITY_VERSION = 1
const ACTIVE_KEY = 'active'
const BUNDLE_VERSION = 1
const PBKDF2_ITERATIONS = 600_000
const encoder = new TextEncoder()
const decoder = new TextDecoder()

export async function createKeyProvider() {
  const keyPair = await crypto.subtle.generateKey(
    { name: 'Ed25519' },
    true,
    ['sign', 'verify'],
  )
  return providerFromKeyPair(keyPair)
}

export async function loadLocalKeyProvider(passphrase) {
  const encoded = localStorage.getItem(STORAGE_KEY)
  if (!encoded) throw new Error('No saved identity on this browser')
  return importEncryptedKeyProvider(encoded, passphrase)
}

export async function importEncryptedKeyProvider(encoded, passphrase) {
  if (typeof encoded !== 'string' || encoded.length > 16_384) {
    throw new Error('Saved identity is damaged')
  }
  let bundle
  try {
    bundle = JSON.parse(encoded)
  } catch {
    throw new Error('Saved identity is damaged')
  }
  validateBundle(bundle)
  const wrappingKey = await deriveWrappingKey(passphrase, fromB64url(bundle.salt), bundle.iterations)
  let plaintext
  try {
    plaintext = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: fromB64url(bundle.iv), additionalData: bundleAad() },
      wrappingKey,
      fromB64url(bundle.ciphertext),
    )
  } catch {
    throw new Error('Wrong passphrase or damaged saved identity')
  }
  let privateJwk
  try {
    ({ private_jwk: privateJwk } = JSON.parse(decoder.decode(plaintext)))
  } catch {
    throw new Error('Saved identity is damaged')
  }
  const privateKey = await crypto.subtle.importKey(
    'jwk', privateJwk, { name: 'Ed25519' }, true, ['sign'],
  )
  // The public half comes from the *decrypted* private key, never from
  // bundle.public_key: that field sits outside the AES-GCM ciphertext and
  // outside its associated data, so nothing authenticates it. Trusting it would
  // let a damaged file produce a provider that advertises one key and signs with
  // another — which surfaces as an unexplained server-side auth failure rather
  // than as the damaged identity it is.
  if (typeof privateJwk?.x !== 'string') throw new Error('Saved identity is damaged')
  const publicKey = await crypto.subtle.importKey(
    'jwk', { kty: 'OKP', crv: 'Ed25519', x: privateJwk.x, ext: true },
    { name: 'Ed25519' }, true, ['verify'],
  )
  return providerFromKeyPair({ privateKey, publicKey })
}

export async function saveLocalKeyProvider(provider, passphrase) {
  localStorage.setItem(STORAGE_KEY, await exportEncryptedKeyProvider(provider, passphrase))
}

// Saving is complete only when the browser can read back this exact identity.
// Both browser surfaces use this seam so neither can claim that a different or
// silently discarded key is a usable backup.
export async function saveVerifiedLocalKeyProvider(provider, passphrase) {
  await saveLocalKeyProvider(provider, passphrase)
  if (!localKeyMatches(provider)) {
    throw new Error(
      'This browser did not keep the encrypted key. Export it to a file instead.',
    )
  }
}

export async function downloadEncryptedKeyProvider(provider, passphrase, filename) {
  const encoded = await exportEncryptedKeyProvider(provider, passphrase)
  const blob = new Blob([encoded], { type: 'application/json' })
  const url = URL.createObjectURL(blob)
  try {
    const link = document.createElement('a')
    link.href = url
    link.download = filename
    link.click()
  } finally {
    URL.revokeObjectURL(url)
  }
}

// The active identity of this browser. It is held as a live key pair so every
// page of this origin uses the same signing key without asking for a passphrase
// again; an encrypted export remains the way to carry the identity elsewhere.
// The trade is deliberate: a passphrase on every page load is what makes people
// reuse one weak phrase, and this origin serves no third-party code.
export async function storeActiveKeyProvider(provider) {
  const database = await openIdentityDatabase()
  try {
    await identityTransaction(
      database, 'readwrite',
      store => store.put({ id: ACTIVE_KEY, key_pair: provider.keyPair }))
  } finally {
    database.close()
  }
}

export async function loadActiveKeyProvider() {
  if (!globalThis.indexedDB) return null
  let database
  try {
    database = await openIdentityDatabase()
  } catch {
    return null
  }
  try {
    const stored = await identityTransaction(
      database, 'readonly', store => store.get(ACTIVE_KEY))
    const keyPair = stored?.key_pair
    if (!keyPair?.privateKey || !keyPair?.publicKey) return null
    return providerFromKeyPair(keyPair)
  } catch {
    return null
  } finally {
    database.close()
  }
}

export async function clearActiveKeyProvider() {
  if (!globalThis.indexedDB) return
  const database = await openIdentityDatabase()
  try {
    await identityTransaction(
      database, 'readwrite', store => store.delete(ACTIVE_KEY))
  } finally {
    database.close()
  }
}

function openIdentityDatabase() {
  return new Promise((resolve, reject) => {
    const open = indexedDB.open(IDENTITY_DATABASE, IDENTITY_VERSION)
    open.onupgradeneeded = () => {
      if (!open.result.objectStoreNames.contains(IDENTITY_STORE)) {
        open.result.createObjectStore(IDENTITY_STORE, { keyPath: 'id' })
      }
    }
    open.onsuccess = () => resolve(open.result)
    open.onerror = () => reject(open.error || new Error('no identity storage'))
    open.onblocked = () => reject(new Error('identity storage is blocked'))
  })
}

function identityTransaction(database, mode, operation) {
  return new Promise((resolve, reject) => {
    const transaction = database.transaction(IDENTITY_STORE, mode)
    const request = operation(transaction.objectStore(IDENTITY_STORE))
    transaction.oncomplete = () => resolve(request.result)
    transaction.onerror = () => reject(
      transaction.error || new Error('identity storage failed'))
    transaction.onabort = transaction.onerror
  })
}

export async function exportEncryptedKeyProvider(provider, passphrase) {
  if (typeof passphrase !== 'string' || passphrase.length < 12) {
    throw new Error('Use a passphrase of at least 12 characters')
  }
  const salt = crypto.getRandomValues(new Uint8Array(16))
  const iv = crypto.getRandomValues(new Uint8Array(12))
  const wrappingKey = await deriveWrappingKey(passphrase, salt, PBKDF2_ITERATIONS)
  const privateJwk = await crypto.subtle.exportKey('jwk', provider.keyPair.privateKey)
  const plaintext = encoder.encode(JSON.stringify({ private_jwk: privateJwk }))
  const ciphertext = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv, additionalData: bundleAad() }, wrappingKey, plaintext,
  )
  const publicJwk = await crypto.subtle.exportKey('jwk', provider.keyPair.publicKey)
  return JSON.stringify({
    version: BUNDLE_VERSION,
    kdf: 'PBKDF2-SHA-256',
    iterations: PBKDF2_ITERATIONS,
    salt: b64url(salt),
    cipher: 'AES-256-GCM',
    iv: b64url(iv),
    ciphertext: b64url(new Uint8Array(ciphertext)),
    public_key: publicJwk.x,
  })
}

export function hasLocalKeyProvider() {
  return localStorage.getItem(STORAGE_KEY) !== null
}

// Whether the saved bundle holds *this* key, not merely some key. The UI needs
// the distinction: telling someone their identity is saved when a different,
// older one is stored invites them to close the tab on a key that exists
// nowhere. Read from the bundle's unauthenticated public field, which is only
// ever trusted for this UI answer and never for signing.
export function localKeyMatches(provider) {
  const encoded = localStorage.getItem(STORAGE_KEY)
  if (!encoded) return false
  try {
    return JSON.parse(encoded).public_key === b64url(provider.publicKey)
  } catch {
    return false
  }
}

async function providerFromKeyPair(keyPair) {
  const publicKey = new Uint8Array(await crypto.subtle.exportKey('raw', keyPair.publicKey))
  return {
    keyPair,
    publicKey,
    sign: bytes => crypto.subtle.sign('Ed25519', keyPair.privateKey, bytes),
  }
}

async function deriveWrappingKey(passphrase, salt, iterations) {
  if (typeof passphrase !== 'string') throw new Error('A passphrase is required')
  const material = await crypto.subtle.importKey(
    'raw', encoder.encode(passphrase), 'PBKDF2', false, ['deriveKey'],
  )
  return crypto.subtle.deriveKey(
    { name: 'PBKDF2', hash: 'SHA-256', salt, iterations }, material,
    { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt'],
  )
}

function validateBundle(bundle) {
  if (!bundle || bundle.version !== BUNDLE_VERSION || bundle.kdf !== 'PBKDF2-SHA-256' ||
      bundle.cipher !== 'AES-256-GCM' || bundle.iterations !== PBKDF2_ITERATIONS ||
      typeof bundle.salt !== 'string' || typeof bundle.iv !== 'string' ||
      typeof bundle.ciphertext !== 'string' || typeof bundle.public_key !== 'string') {
    throw new Error('Saved identity has an unsupported format')
  }
}

function bundleAad() {
  return encoder.encode('quod-client-key-v1')
}

// The one base64url codec: it carries keys, nonces and signatures, so a second
// copy would be a second thing to fix.
export function b64url(bytes) {
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '')
}

export function fromB64url(value) {
  if (typeof value !== 'string' || value.length % 4 === 1) {
    throw new Error('Malformed encoded value')
  }
  const padded = value.replaceAll('-', '+').replaceAll('_', '/') + '='.repeat((4 - value.length % 4) % 4)
  const binary = atob(padded)
  return Uint8Array.from(binary, char => char.charCodeAt(0))
}
