import { strict as assert } from 'node:assert'
import { test } from 'node:test'
import { createHash } from 'node:crypto'
import { createRenderResources } from '../src/render-resources.js'

const bytes = new TextEncoder().encode('verified asset fixture')
const digest = createHash('sha256').update(bytes).digest('hex')
const binding = { digest, slot: 'base_colour', repeat: [1, 2.5] }
function fixture() {
  let reads = 0
  const decoded = []
  const resources = createRenderResources(null, {
    fetchAsset: async () => { reads++; return new Response(bytes) },
    decode: () => {
      const texture = { disposed: 0, dispose() { this.disposed++ } }
      decoded.push(texture)
      return { texture, ready: Promise.resolve() }
    },
  })
  return { resources, decoded, reads: () => reads }
}

test('shared bindings retain textures until their last consumer leaves', async () => {
  const { resources, decoded, reads } = fixture()
  const a = resources.acquire(binding)
  const b = resources.acquire(binding)
  const [one, two] = await Promise.all([a.ready, b.ready])
  assert.equal(one, two)
  assert.equal(reads(), 1)
  assert.equal(decoded.length, 1)
  assert.equal(one.gammaSpace, true)
  assert.equal(one.vScale, 2.5)
  a.release()
  assert.equal(one.disposed, 0)
  const c = resources.acquire(binding)
  assert.equal(await c.ready, one)
  assert.equal(reads(), 1)
  b.release(); c.release(); c.release()
  assert.equal(one.disposed, 1)
  resources.dispose()
})

test('different bindings share verified bytes and keep independent sampling', async () => {
  const { resources, decoded, reads } = fixture()
  const a = resources.acquire(binding)
  const b = resources.acquire({ ...binding, slot: 'normal', repeat: [3, 4] })
  const [one, two] = await Promise.all([a.ready, b.ready])
  assert.equal(reads(), 1)
  assert.equal(decoded.length, 2)
  assert.notEqual(one, two)
  assert.equal(one.gammaSpace, true)
  assert.equal(two.gammaSpace, false)
  assert.equal(two.vScale, 4)
  resources.dispose()
  a.release(); b.release()
  assert.equal(one.disposed, 1)
  assert.equal(two.disposed, 1)
  assert.throws(() => resources.acquire(binding), /disposed/)
})

test('corrupted bytes fail before image decoding', async () => {
  let decodes = 0
  const resources = createRenderResources(null, {
    fetchAsset: async () => new Response('wrong bytes'),
    decode: () => { decodes++; throw new Error('must not decode') },
  })
  const lease = resources.acquire(binding)
  await assert.rejects(lease.ready, /digest mismatch/)
  assert.equal(decodes, 0)
  lease.release(); resources.dispose()
})

test('last release cancels fetch; a late fetch response cannot create a texture', async () => {
  let complete, signal, decodes = 0
  const resources = createRenderResources(null, {
    fetchAsset: (_url, options) => {
      signal = options.signal
      return new Promise(resolve => { complete = resolve })
    },
    decode: () => { decodes++; throw new Error('must not decode') },
  })
  const lease = resources.acquire(binding)
  lease.release()
  assert.equal(signal.aborted, true)
  complete(new Response(bytes))
  assert.equal(await lease.ready, null)
  assert.equal(decodes, 0)
  resources.dispose()
})

test('release during decode disposes immediately and ignores late completion', async () => {
  let complete, started
  const loading = new Promise(resolve => { started = resolve })
  const texture = { disposed: 0, dispose() { this.disposed++ } }
  const resources = createRenderResources(null, {
    fetchAsset: async () => new Response(bytes),
    decode: () => {
      started()
      return { texture, ready: new Promise(resolve => { complete = resolve }) }
    },
  })
  const lease = resources.acquire(binding)
  await loading
  lease.release()
  assert.equal(texture.disposed, 1)
  complete()
  assert.equal(await lease.ready, null)
  resources.dispose()
})
