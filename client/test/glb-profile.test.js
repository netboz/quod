import { strict as assert } from 'node:assert'
import { test } from 'node:test'
import { readFileSync } from 'node:fs'
import { validateGlb } from '../src/glb-profile.js'

const fixture = readFileSync(new URL('./fixtures/asymmetric.glb', import.meta.url))
const jsonLength = fixture.readUInt32LE(12)
const document = JSON.parse(fixture.subarray(20, 20 + jsonLength).toString())
const binChunk = fixture.subarray(20 + jsonLength)
const limits = [8000000, 16000000, 250000, 250000, 1024, 256, 16000000]

function changed(edit) {
  const doc = structuredClone(document)
  edit(doc)
  const json = Buffer.from(JSON.stringify(doc))
  const padded = Buffer.concat([json, Buffer.alloc((4 - json.length % 4) % 4, 32)])
  const header = Buffer.alloc(20)
  header.write('glTF', 0)
  header.writeUInt32LE(2, 4)
  header.writeUInt32LE(20 + padded.length + binChunk.length, 8)
  header.writeUInt32LE(padded.length, 12)
  header.write('JSON', 16)
  return Buffer.concat([header, padded, binChunk])
}

test('asymmetric static GLB measures its actual geometry, hierarchy and PNG', () => {
  const { costs, boundsMm, document: doc } = validateGlb(fixture, limits)
  assert.deepEqual(costs, [fixture.length, 96, 6, 2, 3, 2, 4])
  assert.deepEqual(boundsMm, [-300, 0, -400, 1200, 1400, 300])
  assert.equal(doc.meshes.length, 2)
  assert.equal(doc.materials.length, 2)
  assert.equal(doc.nodes[0].extras.depicts, 'forged')
})

test('each scene node referencing a mesh counts its drawn vertices and triangles', () => {
  const reused = changed(doc => {
    doc.nodes[0].children.push(3)
    doc.nodes.push({ mesh: 0, translation: [2, 0, 0] })
  })
  const { costs, boundsMm } = validateGlb(reused)
  assert.deepEqual(costs.slice(2), [9, 3, 4, 2, 4])
  assert.deepEqual(boundsMm, [-300, 0, -400, 3200, 1400, 300])
  assert.throws(() => validateGlb(reused, [8000000, 16000000, 9, 2, 4, 2, 4]),
    /triangles exceeded/)
})

test('external resources, extensions and dynamic features fail before loading', () => {
  const changes = [
    doc => { doc.buffers[0].uri = 'missing.bin' },
    doc => { doc.images[0].uri = 'missing.png' },
    doc => { doc.extensionsUsed = ['KHR_draco_mesh_compression'] },
    doc => { doc.nodes[0].extensions = { KHR_lights_punctual: {} } },
    doc => { doc.animations = [{}] },
    doc => { doc.skins = [{}] },
    doc => { doc.meshes[0].primitives[0].targets = [{}] },
    doc => { doc.meshes[0].primitives[0].mode = 1 },
    doc => { doc.nodes[0].camera = 0 },
    doc => { doc.accessors[0].sparse = {} },
    doc => { doc.accessors[0].min[0] = -100 },
    doc => { doc.accessors[0].max[0] = 100 },
    doc => { doc.accessors[2].type = 'VEC3' },
    doc => { doc.accessors[2].componentType = 5123 },
    doc => { doc.nodes[0].rotation = [0, 0, 0, 2] },
    doc => {
      doc.accessors.push({ bufferView: 0, componentType: 5123, count: 3, type: 'SCALAR' })
      doc.meshes[0].primitives[0].indices = doc.accessors.length - 1
    },
  ]
  for (const edit of changes) assert.throws(() => validateGlb(changed(edit), limits))
})

test('reused accessors retain their measured costs and bounds', () => {
  const repeated = changed(doc => {
    doc.meshes[0].primitives.push(structuredClone(doc.meshes[0].primitives[0]))
  })
  const { costs, boundsMm } = validateGlb(repeated)
  assert.equal(costs[2], 9)
  assert.equal(costs[3], 3)
  assert.deepEqual(boundsMm, [-300, 0, -400, 1200, 1400, 300])
})

test('each measured resource is checked against its authorized allowance', () => {
  const { costs } = validateGlb(fixture)
  for (let i = 0; i < costs.length; i++) {
    const allowed = [...costs]
    allowed[i]--
    assert.throws(() => validateGlb(fixture, allowed), /exceeded/)
  }
})

test('unallocated presentation still validates and measures the asset', () => {
  assert.deepEqual(validateGlb(fixture, Array(7).fill(Infinity)).costs, validateGlb(fixture, limits).costs)
  assert.throws(() => validateGlb(fixture, [Infinity, 1, Infinity, Infinity, Infinity, Infinity, Infinity]), /geometry bytes exceeded/)
})
