import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { NullEngine } from '@babylonjs/core/Engines/nullEngine.js'
import { Scene } from '@babylonjs/core/scene.js'
import { createRenderResources } from '../src/render-resources.js'
import { validateGlb } from '../src/glb-profile.js'
import { paintMarks, clearMarks } from '../src/scene.js'

function sharedMesh() {
  const doc = { asset: { version: '2.0' }, scene: 0, scenes: [{ nodes: [0, 1] }],
    nodes: [{ mesh: 0 }, { mesh: 0 }], meshes: [{ primitives: [{ attributes: { POSITION: 0 } }] }],
    buffers: [{ byteLength: 36 }], bufferViews: [{ buffer: 0, byteOffset: 0, byteLength: 36 }],
    accessors: [{ bufferView: 0, componentType: 5126, count: 3, type: 'VEC3', min: [0, 0, 0], max: [1, 1, 0] }] }
  const json = Buffer.from(JSON.stringify(doc)), padded = Buffer.alloc(Math.ceil(json.length / 4) * 4, 32)
  json.copy(padded)
  const bin = Buffer.from(new Float32Array([0, 0, 0, 1, 0, 0, 0, 1, 0]).buffer)
  const bytes = Buffer.alloc(28 + padded.length + bin.length)
  bytes.writeUInt32LE(0x46546c67, 0); bytes.writeUInt32LE(2, 4); bytes.writeUInt32LE(bytes.length, 8)
  bytes.writeUInt32LE(padded.length, 12); bytes.writeUInt32LE(0x4e4f534a, 16); padded.copy(bytes, 20)
  const at = 20 + padded.length
  bytes.writeUInt32LE(bin.length, at); bytes.writeUInt32LE(0x004e4942, at + 4); bin.copy(bytes, at + 8)
  return bytes
}

for (const [label, bytes] of [
  ['shared mesh without extensions', sharedMesh()],
  ['pinned Vive appearance', readFileSync(new URL('../../ui/public/assets/models/bd201855c8114b9b0e9cdd465d6f08413d18604894c839fb78d54d890c2adc94.glb', import.meta.url))],
]) test(`${label}: real decoder and occurrences share one verified template`, async () => {
  const engine = new NullEngine(), scene = new Scene(engine)
  const { costs, boundsMm } = validateGlb(bytes)
  const digest = createHash('sha256').update(bytes).digest('hex')
  let requests = 0
  const resources = createRenderResources(scene, { fetchAsset: async url => {
    assert.equal(url, `/assets/models/${digest}.glb`); requests++; return new Response(bytes)
  } })
  const size = { digest, profile: 'gltf2-static-v1', allowed: costs.map(n => Math.max(1, n)), bounds: boundsMm,
    scale: 1, pivot: [0, 0, 0], front: '-z' }
  const errors = []
  const marks = paintMarks(scene, ['left', 'right'].map(id => ({ id, kind: 'mesh', size,
    transform: { x: 0, y: 0, z: 0, rx: 0, ry: 0, rz: 0 }, parent: null, depicts: null })),
    new Map(), resources, error => errors.push(error))
  try {
    await Promise.all([...marks.values()].map(entry => entry.ready))
    assert.deepEqual(errors, [])
    assert.equal(requests, 1)
    const left = marks.get('left').node.getChildMeshes(), right = marks.get('right').node.getChildMeshes()
    assert.ok(left.length > 0)
    assert.equal(left.length, right.length)
    assert.notEqual(left[0], right[0])
    clearMarks(marks)
    assert.ok(left.every(mesh => mesh.isDisposed()))
    assert.ok(right.every(mesh => mesh.isDisposed()))
  } finally { clearMarks(marks); resources.dispose(); scene.dispose(); engine.dispose() }
})
