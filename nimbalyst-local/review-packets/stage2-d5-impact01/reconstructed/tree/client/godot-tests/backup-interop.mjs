import { readFile } from 'node:fs/promises'
import assert from 'node:assert/strict'
import { importEncryptedKeyProvider, b64url, fromB64url } from '../src/key-provider.js'
const corpus = JSON.parse(await readFile(new URL('../test/fixtures/native-contract/contracts.json', import.meta.url)))
const imported = await importEncryptedKeyProvider(await readFile(process.argv[2], 'utf8'), corpus.passphrase)
assert.equal(b64url(imported.publicKey), corpus.public_key)
assert.equal(b64url(new Uint8Array(await imported.sign(fromB64url(corpus.requests[0].bytes)))), corpus.requests[0].signature)
console.log('PASS actual exported backup imported and signed through the existing browser key owner')
