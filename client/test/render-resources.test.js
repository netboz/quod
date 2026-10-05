import { strict as assert } from 'node:assert'
import { test } from 'node:test'
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
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

const modelBytes = readFileSync(new URL('./fixtures/asymmetric.glb', import.meta.url))
const modelDigest = createHash('sha256').update(modelBytes).digest('hex')
const allowed = [8000000, 16000000, 250000, 250000, 1024, 256, 16000000]
const model = { digest: modelDigest, profile: 'gltf2-static-v1', allowed,
  bounds: [-300, 0, -400, 1200, 1400, 300] }

test('two model occurrences share verified bytes and one decoded template', async () => {
  let fetched = 0, decoded = 0, disposed = 0
  const resources = createRenderResources(null, {
    fetchAsset: async path => {
      assert.equal(path, `/assets/models/${modelDigest}.glb`)
      fetched++
      return new Response(modelBytes)
    },
    decodeModel: async () => {
      decoded++
      return { dispose() { disposed++ } }
    },
  })
  const a = resources.acquireModel(model)
  const b = resources.acquireModel(model)
  const [one, two] = await Promise.all([a.ready, b.ready])
  assert.equal(one, two)
  assert.deepEqual([fetched, decoded], [1, 1])
  a.release()
  assert.equal(disposed, 0)
  const c = resources.acquireModel(model)
  assert.equal(await c.ready, one)
  assert.deepEqual([fetched, decoded], [1, 1])
  b.release(); c.release()
  assert.equal(disposed, 1)
  resources.dispose()
})

test('measured costs deny decode and a stricter occurrence independently', async () => {
  let decoded = 0
  const resources = createRenderResources(null, {
    fetchAsset: async () => new Response(modelBytes),
    decodeModel: async () => { decoded++; return { dispose() {} } },
  })
  const denied = resources.acquireModel({ ...model,
    allowed: [modelBytes.length, 96, 6, 1, 3, 2, 4] })
  await assert.rejects(denied.ready, /triangles exceeded/)
  assert.equal(decoded, 0)
  denied.release()
  const granted = resources.acquireModel(model)
  assert.ok(await granted.ready)
  assert.equal(decoded, 1)
  granted.release(); resources.dispose()
})

test('a declared frame must match bounds measured from the verified asset', async () => {
  let decoded = 0
  const resources = createRenderResources(null, {
    fetchAsset: async () => new Response(modelBytes),
    decodeModel: async () => { decoded++; return { dispose() {} } },
  })
  const lease = resources.acquireModel({ ...model,
    bounds: [-400, -100, -800, 1300, 1800, 500] })
  await assert.rejects(lease.ready, /asset-local bounds differ/)
  assert.equal(decoded, 0)
  lease.release(); resources.dispose()
})

test('a late model decode cannot restore a released template', async () => {
  let complete, begun, disposed = 0
  const loading = new Promise(resolve => { begun = resolve })
  const resources = createRenderResources(null, {
    fetchAsset: async () => new Response(modelBytes),
    decodeModel: () => {
      begun()
      return new Promise(resolve => { complete = resolve })
    },
  })
  const lease = resources.acquireModel(model)
  await loading
  lease.release()
  complete({ dispose() { disposed++ } })
  assert.equal(await lease.ready, null)
  assert.equal(disposed, 1)
  resources.dispose()
})

test('a model digest mismatch stops before GLB parse and Babylon decode', async () => {
  let decoded = 0
  const resources = createRenderResources(null, {
    fetchAsset: async () => new Response('corrupt GLB'),
    decodeModel: async () => { decoded++; throw new Error('must not decode') },
  })
  const lease = resources.acquireModel(model)
  await assert.rejects(lease.ready, /digest mismatch/)
  assert.equal(decoded, 0)
  lease.release(); resources.dispose()
})

test('model transfer allowance stops the stream before GLB parsing or decode', async () => {
  let decoded = 0
  const resources = createRenderResources(null, {
    fetchAsset: async () => new Response(modelBytes),
    decodeModel: async () => { decoded++; throw new Error('must not decode') },
  })
  const lease = resources.acquireModel({ ...model, allowed: [20, ...allowed.slice(1)] })
  await assert.rejects(lease.ready, /transfer bytes exceeded/)
  assert.equal(decoded, 0)
  lease.release(); resources.dispose()
})
