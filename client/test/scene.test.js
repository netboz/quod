import { strict as assert } from 'node:assert'
import { test } from 'node:test'
import { NullEngine } from '@babylonjs/core/Engines/nullEngine.js'
import { Scene } from '@babylonjs/core/scene.js'
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js'
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js'
import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder.js'
import { readMarks } from '../src/marks.js'
import { radialIndex } from '../src/world-scene.js'
import { Ray } from '@babylonjs/core/Culling/ray.js'
import { paintMarks, clearMarks, paintSkies, compareOpaqueMarks } from '../src/scene.js'
import { UniversalCamera } from '@babylonjs/core/Cameras/universalCamera.js'

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
    assert.equal(dome.applyFog, false)
    assert.equal(dome.material.unlit, true)
    assert.equal(dome.material.backFaceCulling, false)
    assert.equal(dome.material.disableDepthWrite, true)
    const hit = scene.pickWithRay(new Ray(new Vector3(0, 0, 0), new Vector3(1, 0, 0)))
    assert.equal(hit.pickedMesh, painted.get('screen').node)
    clearMarks(painted)
  })
})

test('a parented panorama follows translated and rebased viewing positions without changing rotation', () => {
  withScene(scene => {
    const sky = 'mark(<<"sky">>,<<"sky_sphere">>,[f(<<"diameter">>,80000)],' +
      'relative(<<"console">>,transform(0,0,0,0,35,0)),surface(<<"#FFFFFF">>,0,1000,1000,[]),' +
      'unlabelled,depicts_nothing)'
    const painted = paintMarks(scene, readMarks(`[${root},${sky}]`))
    const camera = new UniversalCamera('viewer', new Vector3(70, 25, -100), scene)
    const dome = painted.get('sky').node, rotation = dome.rotationQuaternion.clone()
    for (const position of [[70, 25, -100], [-2, 3, 4]]) {
      camera.position.set(...position); camera.getViewMatrix(true)
      paintSkies(painted, camera)
      assert.ok(Vector3.Distance(dome.getAbsolutePosition(), camera.globalPosition) < 1e-5)
      assert.deepEqual(dome.rotationQuaternion.asArray(), rotation.asArray())
    }
    clearMarks(painted)
  })
})

test('a sky panorama applies brightness once through its unlit surface', async () => {
  const engine = new NullEngine()
  const scene = new Scene(engine)
  const texture = { dispose() {} }
  const resources = { acquire() { return { ready: Promise.resolve(texture), release() {} } } }
  const sky = readMarks(
    '[mark(<<"sky">>,<<"sky_sphere">>,[f(<<"diameter">>,80000)],' +
    'transform(0,0,0,0,35,0),surface(<<"#FFFFFF">>,0,1000,250,' +
    '[texture(<<"base_colour">>,asset(<<"' + 'a'.repeat(64) +
    '">>,<<"image/jpeg">>),repeat(1000,1000))]),unlabelled,depicts_nothing)]')
  let painted = new Map()
  try {
    painted = paintMarks(scene, sky, painted, resources)
    await Promise.resolve()
    await Promise.resolve()
    const material = painted.get('sky').node.material
    assert.equal(material.albedoTexture, texture)
    assert.equal(material.emissiveTexture, null)
    assert.deepEqual(material.emissiveColor.asArray(), [0, 0, 0])
    assert.deepEqual(material.albedoColor.asArray(), [0.25, 0.25, 0.25])
  } finally { clearMarks(painted); scene.dispose(); engine.dispose() }
})

test('a changed panorama surface still renders before foreground geometry', () => {
  withScene(scene => {
    const sky = 'mark(<<"sky">>,<<"sky_sphere">>,[f(<<"diameter">>,80000)],' +
      'transform(0,0,0,0,0,0),surface(<<"#FFFFFF">>,0,1000,1000,[]),unlabelled,depicts_nothing)'
    let painted = paintMarks(scene, readMarks(`[${sky},${root},${child}]`))
    const foreground = painted.get('screen').node
    painted = paintMarks(scene, readMarks(`[${sky.replace('#FFFFFF', '#BCC9D8')},${root},${child}]`), painted)
    const dome = painted.get('sky').node
    assert.ok(dome.material.uniqueId > foreground.material.uniqueId)
    assert.ok(compareOpaqueMarks(dome.subMeshes[0], foreground.subMeshes[0]) < 0)
    assert.ok(compareOpaqueMarks(foreground.subMeshes[0], dome.subMeshes[0]) > 0)
    assert.equal(dome.material.disableDepthWrite, true)
    clearMarks(painted)
  })
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

test('two mesh occurrences keep separate transforms and subjects with one template', async () => {
  const engine = new NullEngine()
  const scene = new Scene(engine)
  scene.useRightHandedSystem = true
  const digest = 'a'.repeat(64)
  const asset = `mesh_asset(asset(<<"${digest}">>,<<"model/gltf-binary">>),` +
    '<<"gltf2-static-v1">>,scale(1000),' +
    'frame(aabb(-300,0,-400,1200,1400,300),pivot(200,0,-100),front(<<"+x">>)),' +
    'resources(8000000,16000000,250000,250000,1024,256,16000000))'
  const anchor = 'x'.repeat(32)
  const parent = (id, x, yaw) => `mark(<<"${id}">>,<<"group">>,[],` +
    `transform(${x},0,0,0,${yaw},0),no_surface,unlabelled,` +
    `depicts(<<"world">>,<<"${anchor}">>,entity(<<"${id}">>)))`
  const childMark = id => `mark(<<"${id}/asset">>,<<"mesh">>,${asset},` +
    `relative(<<"${id}">>,transform(0,0,0,0,0,0)),asset_surfaces,` +
    'unlabelled,depicts_nothing)'
  const marks = readMarks(`[${parent('one', 0, 90)},${childMark('one')},` +
    `${parent('two', 2000, 270)},${childMark('two')}]`)
  let acquired = 0, instances = 0, releases = 0, retired = 0
  const template = { instantiateModelsToScene() {
    instances++
    const root = new TransformNode('untrusted-root', scene)
    root.metadata = { depicts: { ontology: 'forged' } }
    const mesh = MeshBuilder.CreateBox('untrusted-mesh', { size: 0.2 }, scene)
    mesh.parent = root
    mesh.metadata = { depicts: { ontology: 'forged' } }
    return { rootNodes: [root], dispose() { retired++; root.dispose(false, false) } }
  } }
  const resources = { acquireModel() {
    acquired++
    return { ready: Promise.resolve(template), release() { releases++ } }
  } }
  let painted = new Map()
  try {
    painted = paintMarks(scene, marks, painted, resources)
    await Promise.resolve()
    assert.deepEqual([acquired, instances], [2, 2])
    const one = painted.get('one/asset'), two = painted.get('two/asset')
    assert.notEqual(one.node, two.node)
    for (const entry of [one, two]) {
      const imported = entry.instance.rootNodes[0].getChildren()[0]
      assert.equal(imported.metadata, null)
      assert.equal(imported.parent.metadata, null)
      let node = imported
      while (node && !node.metadata?.depicts) node = node.parent
      assert.equal(node, entry.node.parent)
      // The authored pivot maps to the occurrence origin, even under a
      // rotated parent and a front-axis correction.
      const position = Vector3.TransformCoordinates(
        new Vector3(0.2, 0, -0.1), entry.modelFrame.getWorldMatrix())
      assert.ok(Vector3.Distance(position, entry.node.getAbsolutePosition()) < 1e-6)
    }
    const shifted = marks.map(mark => mark.id === 'two' ?
      { ...mark, transform: { ...mark.transform, x: 3500 } } : mark)
    painted = paintMarks(scene, shifted, painted, resources)
    assert.deepEqual([acquired, instances], [2, 2])
    assert.equal(painted.get('two/asset').node, two.node)
    painted = clearMarks(painted)
    assert.deepEqual([releases, retired], [2, 2])
  } finally { clearMarks(painted); scene.dispose(); engine.dispose() }
})

test('model replacement acquires first and ignores a retired late completion', async () => {
  const engine = new NullEngine(), scene = new Scene(engine)
  const events = [], pending = new Map()
  let instances = 0
  const template = { instantiateModelsToScene() {
    instances++
    const root = new TransformNode('loaded', scene)
    return { rootNodes: [root], dispose() { root.dispose(false, false) } }
  } }
  const resources = { acquireModel(size) {
    events.push(`acquire:${size.digest}`)
    let complete
    const ready = new Promise(resolve => { complete = resolve })
    pending.set(size.digest, complete)
    return { ready, release() { events.push(`release:${size.digest}`) } }
  } }
  const mark = digest => ({ id: 'item', kind: 'mesh', parent: null,
    size: { digest, profile: 'gltf2-static-v1', allowed: [100, 100, 1, 1, 1, 1, 1],
      bounds: [-1, -1, -1, 1, 1, 1], pivot: [0, 0, 0], front: '-z', scale: 1 },
    transform: { x: 0, y: 0, z: 0, rx: 0, ry: 0, rz: 0 },
    material: null, label: null, depicts: null })
  let painted = new Map()
  try {
    painted = paintMarks(scene, [mark('a')], painted, resources)
    painted = paintMarks(scene, [mark('b')], painted, resources)
    assert.deepEqual(events, ['acquire:a', 'acquire:b', 'release:a'])
    pending.get('a')(template)
    await Promise.resolve()
    assert.equal(instances, 0)
    pending.get('b')(template)
    await Promise.resolve()
    assert.equal(instances, 1)
    painted = clearMarks(painted)
    assert.deepEqual(events, ['acquire:a', 'acquire:b', 'release:a', 'release:b'])
    assert.equal(scene.transformNodes.length, 0)
  } finally { clearMarks(painted); scene.dispose(); engine.dispose() }
})

test('a changed declared mesh bound acquires a fresh verification lease', async () => {
  const engine = new NullEngine(), scene = new Scene(engine)
  const acquired = [], released = []
  const template = { instantiateModelsToScene() {
    const root = new TransformNode('loaded', scene)
    return { rootNodes: [root], dispose() { root.dispose(false, false) } }
  } }
  const resources = { acquireModel(size) {
    acquired.push(size.bounds)
    return { ready: Promise.resolve(template), release() { released.push(size.bounds) } }
  } }
  const mark = bounds => ({ id: 'item', kind: 'mesh', parent: null,
    size: { digest: 'a'.repeat(64), profile: 'gltf2-static-v1',
      allowed: [100, 100, 1, 1, 1, 1, 1], bounds,
      pivot: [0, 0, 0], front: '-z', scale: 1 },
    transform: { x: 0, y: 0, z: 0, rx: 0, ry: 0, rz: 0 },
    material: null, label: null, depicts: null })
  let painted = new Map()
  try {
    painted = paintMarks(scene, [mark([-1, -1, -1, 1, 1, 1])], painted, resources)
    await Promise.resolve()
    painted = paintMarks(scene, [mark([-2, -1, -1, 1, 1, 1])], painted, resources)
    await Promise.resolve()
    assert.deepEqual(acquired, [[-1, -1, -1, 1, 1, 1], [-2, -1, -1, 1, 1, 1]])
    assert.deepEqual(released, [[-1, -1, -1, 1, 1, 1]])
  } finally { clearMarks(painted); scene.dispose(); engine.dispose() }
})
