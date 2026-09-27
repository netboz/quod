import { strict as assert } from 'node:assert'
import { test } from 'node:test'
import { NullEngine } from '@babylonjs/core/Engines/nullEngine.js'
import { Scene } from '@babylonjs/core/scene.js'
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js'
import { readMarks } from '../src/marks.js'
import { radialIndex } from '../src/world-scene.js'
import { Ray } from '@babylonjs/core/Culling/ray.js'
import { paintMarks, clearMarks } from '../src/scene.js'

const root = 'mark(<<"console">>,<<"group">>,[],transform(1000,0,0,0,90,0),no_surface,unlabelled,depicts_nothing)'
const child = 'mark(<<"screen">>,<<"plane">>,[f(<<"width">>,1000),f(<<"height">>,600)],relative(<<"console">>,transform(0,0,-100,0,0,0)),surface(<<"#F9C80E">>,0,900,700,[]),unlabelled,depicts_nothing)'

function withScene(run) {
  const engine = new NullEngine()
  const scene = new Scene(engine)
  try { run(scene) } finally { scene.dispose(); engine.dispose() }
}

test('hierarchy composes transforms and unchanged snapshots retain engine resources', () => {
  withScene(scene => {
    const marks = readMarks(`[${root},${child}]`)
    let painted = paintMarks(scene, marks)
    const screen = painted.get('screen').node
    const material = screen.material
    screen.computeWorldMatrix(true)
    assert.ok(Vector3.Distance(screen.getAbsolutePosition(), new Vector3(0.9, 0, 0)) < 1e-6)
    assert.equal(material.roughness, 0.9)
    assert.equal(material.metallic, 0)
    painted = paintMarks(scene, marks, painted)
    assert.equal(painted.get('screen').node, screen)
    assert.equal(screen.material, material)
    assert.equal(scene.meshes.length, 1)
    assert.equal(scene.materials.filter(m => m.name.startsWith('mark-material:')).length, 1)
    assert.equal(clearMarks(painted).size, 0)
    assert.equal(scene.meshes.length, 0)
    assert.equal(scene.transformNodes.length, 0)
    assert.equal(scene.materials.filter(m => m.name.startsWith('mark-material:')).length, 0)
  })
})

test('the Babylon adapter builds capsule and torus geometry from neutral dimensions', () => {
  withScene(scene => {
    const surface = 'surface(<<"#F9C80E">>,0,900,0,[])'
    const marks = readMarks(
      `[mark(<<"support">>,<<"capsule">>,[f(<<"diameter">>,460),f(<<"height">>,850)],` +
      `transform(0,425,0,0,0,0),${surface},unlabelled,depicts_nothing),` +
      `mark(<<"ring">>,<<"torus">>,[f(<<"diameter">>,110),f(<<"thickness">>,18)],` +
      `transform(0,0,0,90,0,0),${surface},unlabelled,depicts_nothing)]`)
    let painted = paintMarks(scene, marks)
    const support = painted.get('support').node
    const ring = painted.get('ring').node
    assert.ok(support.getTotalVertices() > 0)
    assert.ok(ring.getTotalVertices() > 0)
    painted = paintMarks(scene, marks, painted)
    assert.equal(painted.get('support').node, support)
    assert.equal(painted.get('ring').node, ring)
    clearMarks(painted)
  })
})

test('the Babylon adapter draws an unlit inward sky which cannot intercept selection', () => {
  withScene(scene => {
    const sky = 'mark(<<"sky">>,<<"sky_sphere">>,[f(<<"diameter">>,80000)],' +
      'transform(0,0,0,0,35,0),surface(<<"#FFFFFF">>,0,1000,1000,[]),' +
      'unlabelled,depicts_nothing)'
    const painted = paintMarks(scene, readMarks(`[${sky},${root},${child}]`))
    const dome = painted.get('sky').node
    assert.equal(dome.isPickable, false)
    assert.equal(dome.material.unlit, true)
    assert.equal(dome.material.backFaceCulling, false)
    assert.equal(dome.material.disableDepthWrite, true)
    const hit = scene.pickWithRay(new Ray(new Vector3(0, 0, 0), new Vector3(1, 0, 0)))
    assert.equal(hit.pickedMesh, painted.get('screen').node)
    clearMarks(painted)
  })
})

test('a sky panorama drives the adapter emissive texture', async () => {
  const engine = new NullEngine()
  const scene = new Scene(engine)
  const texture = { dispose() {} }
  const resources = { acquire() { return { ready: Promise.resolve(texture), release() {} } } }
  const sky = readMarks(
    '[mark(<<"sky">>,<<"sky_sphere">>,[f(<<"diameter">>,80000)],' +
    'transform(0,0,0,0,35,0),surface(<<"#FFFFFF">>,0,1000,1000,' +
    '[texture(<<"base_colour">>,asset(<<"' + 'a'.repeat(64) +
    '">>,<<"image/jpeg">>),repeat(1000,1000))]),unlabelled,depicts_nothing)]')
  let painted = new Map()
  try {
    painted = paintMarks(scene, sky, painted, resources)
    await Promise.resolve()
    await Promise.resolve()
    const material = painted.get('sky').node.material
    assert.equal(material.albedoTexture, texture)
    assert.equal(material.emissiveTexture, texture)
  } finally { clearMarks(painted); scene.dispose(); engine.dispose() }
})

test('reparented children survive removed parents; geometry replacement retires only old resources', () => {
  withScene(scene => {
    let painted = paintMarks(scene, readMarks(`[${root},${child}]`))
    const oldRoot = painted.get('console').node
    const screen = painted.get('screen').node
    const detached = child.replace('relative(<<"console">>,transform(0,0,-100,0,0,0))', 'transform(0,0,0,0,0,0)')
    painted = paintMarks(scene, readMarks(`[${detached}]`), painted)
    assert.ok(oldRoot.isDisposed())
    assert.equal(screen.isDisposed(), false)
    assert.equal(screen.parent, null)
    const changed = detached.replace('1000)', '1200)')
    painted = paintMarks(scene, readMarks(`[${changed}]`), painted)
    assert.ok(screen.isDisposed())
    assert.notEqual(painted.get('screen').node, screen)
    assert.equal(scene.meshes.length, 1)
    assert.equal(scene.materials.filter(m => m.name.startsWith('mark-material:')).length, 1)
    clearMarks(painted)
  })
})

test('malformed hierarchy and material never reach the renderer', () => {
  for (const text of [
    `[${child}]`, `[${child},${root}]`, `[${root},${root}]`,
    `[${root},${child.replace('900,700', '1001,700')}]`,
    `[${root},${child.replace('900,700', '-1,700')}]`,
    `[${root.replace('no_surface', 'surface(<<"#FFFFFF">>, 0, 900, 0, [])')}]`,
  ]) assert.throws(() => readMarks(text))
})


test('the world adapter registers ray picking for rendered geometry', () => {
  withScene(scene => {
    const marks = readMarks(`[${root},${child}]`)
    const painted = paintMarks(scene, marks)
    const screen = painted.get('screen').node
    screen.computeWorldMatrix(true)
    const hit = scene.pickWithRay(new Ray(new Vector3(0, 0, 0), new Vector3(1, 0, 0)))
    assert.equal(hit.pickedMesh, screen)
    assert.equal(hit.pickedMesh.parent, painted.get('console').node)
    clearMarks(painted)
  })
})

test('radial selection starts at the top, proceeds clockwise, and preserves its dead zone', () => {
  assert.equal(radialIndex({ x: 0, y: 0 }, 4), null)
  assert.equal(radialIndex({ x: 0, y: -1 }, 4), 0)
  assert.equal(radialIndex({ x: 1, y: 0 }, 4), 1)
  assert.equal(radialIndex({ x: 0, y: 1 }, 4), 2)
  assert.equal(radialIndex({ x: -1, y: 0 }, 4), 3)
})


test('the neutral transform applies X then Y then Z before translation', () => {
  withScene(scene => {
    scene.useRightHandedSystem = true
    const rotated = root.replace('1000,0,0,0,90,0', '1000,2000,3000,90,90,90')
    const translated = child.replace('transform(0,0,-100,0,0,0)', 'transform(100,200,300,0,0,0)')
    const painted = paintMarks(scene, readMarks(`[${rotated},${translated}]`))
    const mesh = painted.get('screen').node
    mesh.computeWorldMatrix(true)
    // (x,y,z) -> Rx:(x,-z,y) -> Ry:(y,-z,-x) -> Rz:(z,y,-x).
    assert.ok(Vector3.Distance(mesh.getAbsolutePosition(), new Vector3(1.3, 2.2, 2.9)) < 1e-6)
    assert.equal(mesh.material.invertNormalMapX, false)
    assert.equal(mesh.material.invertNormalMapY, true)
    clearMarks(painted)
  })
})

test('textured scene reconciliation retains leases and retires stale completions', async () => {
  const engine = new NullEngine()
  const scene = new Scene(engine)
  const events = [], errors = [], pending = []
  const resources = { acquire(binding) {
    events.push(`acquire:${binding.digest}`)
    let resolve, reject
    const ready = new Promise((yes, no) => { resolve = yes; reject = no })
    const lease = { ready, resolve, reject, release() { events.push(`release:${binding.digest}`) } }
    pending.push(lease)
    return lease
  } }
  const base = readMarks(`[${root},${child}]`)
  const a = { ...base[1], material: { ...base[1].material,
    textures: [{ slot: 'base_colour', digest: 'a', repeat: [1, 1] }] } }
  const b = { ...a, material: { ...a.material,
    textures: [{ slot: 'base_colour', digest: 'b', repeat: [1, 1] }] } }
  let painted = new Map()
  try {
    painted = paintMarks(scene, [base[0], a], painted, resources, e => errors.push(e.message))
    const node = painted.get('screen').node
    assert.equal(node.isVisible, false)
    painted = paintMarks(scene, [base[0], a], painted, resources, e => errors.push(e.message))
    assert.deepEqual(events, ['acquire:a'])
    painted = paintMarks(scene, [base[0], b], painted, resources, e => errors.push(e.message))
    assert.deepEqual(events, ['acquire:a', 'acquire:b', 'release:a'])
    pending[0].resolve(null)
    await pending[0].ready
    await Promise.resolve()
    assert.equal(node.isVisible, false)
    assert.equal(node.material.albedoTexture, null)
    pending[1].reject(new Error('asset unavailable'))
    // Wait for the actual error handler, without timing assumptions.
    await new Promise(resolve => {
      const append = errors.push.bind(errors)
      errors.push = (...values) => { append(...values); resolve() }
    })
    assert.equal(node.isVisible, false)
    assert.match(errors[0], /asset unavailable/)
    painted = clearMarks(painted)
    assert.deepEqual(events, ['acquire:a', 'acquire:b', 'release:a', 'release:b'])
    assert.equal(node.isDisposed(), true)
  } finally { clearMarks(painted); scene.dispose(); engine.dispose() }
})
