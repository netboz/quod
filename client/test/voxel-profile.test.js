import { strict as assert } from 'node:assert'
import { test } from 'node:test'
import { readFileSync } from 'node:fs'
import { decodeVoxel } from '../src/voxel-profile.js'

// Produced by quod_voxel:prepare/5, field_v1(1,500,[plane(1000)],9), chunk 0/0/0.
const fixture = readFileSync(new URL('./fixtures/voxel-plane.qvt', import.meta.url))
const palette = new Map([[9, { colour: '#447722', metallic: 0, roughness: 0.9, emission: 0, textures: [] }]])
const allowed = [500000, 1000000, 20000, 10000]

test('native surface positions, winding and material survive decoding', () => {
  const mesh = decodeVoxel(fixture, palette, allowed)
  assert.equal(mesh.spacing, 500)
  assert.equal(mesh.sharedVertices, 81)
  assert.equal(mesh.indices.length, 128 * 3)
  assert.deepEqual(mesh.costs, [4880, 13824, 384, 128])
  for (let i = 0; i < mesh.indices.length; i++) {
    assert.equal(mesh.positions[3 * i + 1], Math.fround(0.996))
    assert.deepEqual(Array.from(mesh.normals.slice(3 * i, 3 * i + 3)), [0, 1, 0])
    assert.equal(mesh.uvs[2 * i], mesh.positions[3 * i])
    assert.equal(mesh.uvs[2 * i + 1], -mesh.positions[3 * i + 2])
  }
})

test('complete framing, palette and allocation are mandatory', () => {
  assert.throws(() => decodeVoxel(fixture.subarray(0, -1), palette, allowed), /resource length/)
  assert.throws(() => decodeVoxel(fixture, new Map(), allowed), /material 9/)
  assert.throws(() => decodeVoxel(fixture, palette, [4880, 13823, 384, 128]), /geometry bytes exceeded/)
  const damaged = Uint8Array.from(fixture)
  new DataView(damaged.buffer).setUint32(12, 80)
  assert.throws(() => decodeVoxel(damaged, palette, allowed), /shared vertex count/)
  damaged.set(damaged.subarray(16, 28), 28)
  assert.throws(() => decodeVoxel(damaged, palette, allowed), /degenerate triangle/)
})

test('empty and full chunks can carry an empty surface', () => {
  const bytes = new Uint8Array(16), view = new DataView(bytes.buffer)
  view.setUint32(0, 0x51565431); view.setUint32(4, 500)
  const mesh = decodeVoxel(bytes, new Map(), [16, 0, 0, 0])
  assert.equal(mesh.positions.length, 0)
  assert.deepEqual(mesh.costs, [16, 0, 0, 0])
})

test('adjacent negative-coordinate chunks preserve texture phase and vertical walls have nondegenerate UVs', () => {
  const left = decodeVoxel(fixture, palette, allowed, [996000, 0, 0])
  const right = decodeVoxel(fixture, palette, allowed)
  const leftEdge = [], rightEdge = []
  for (let i = 0; i < left.indices.length; i++) {
    if (left.positions[3 * i] === 4) leftEdge.push([left.uvs[2 * i] % 1000, left.uvs[2 * i + 1]])
    if (right.positions[3 * i] === 0) rightEdge.push([right.uvs[2 * i] % 1000, right.uvs[2 * i + 1]])
  }
  assert.deepEqual([...new Set(leftEdge.map(JSON.stringify))].sort(), [...new Set(rightEdge.map(JSON.stringify))].sort())
  const wall = Uint8Array.from(fixture), data = new DataView(wall.buffer)
  // A cyclic axis permutation is a rotation and preserves winding.
  for (let t = 0; t < 128; t++) for (let c = 0; c < 3; c++) {
    const at = 16 + t * 38 + c * 12
    const x = data.getUint32(at), y = data.getUint32(at + 4), z = data.getUint32(at + 8)
    data.setUint32(at, y); data.setUint32(at + 4, z); data.setUint32(at + 8, x)
  }
  const mesh = decodeVoxel(wall, palette, allowed)
  for (let t = 0; t < 128; t++) {
    const [u, v, a, b, c, d] = mesh.uvs.slice(t * 6, t * 6 + 6)
    assert.notEqual((a - u) * (d - v) - (c - u) * (b - v), 0)
  }
})
