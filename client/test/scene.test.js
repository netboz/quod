import { strict as assert } from 'node:assert'
import { test } from 'node:test'
import { NullEngine } from '@babylonjs/core/Engines/nullEngine.js'
import { Scene } from '@babylonjs/core/scene.js'
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js'
import { readMarks } from '../src/marks.js'
import '../src/world-scene.js'
import { Ray } from '@babylonjs/core/Culling/ray.js'
import { paintMarks, clearMarks } from '../src/scene.js'

const root = 'mark(<<"console">>,<<"group">>,[],transform(1000,0,0,0,90,0),no_surface,unlabelled,depicts_nothing)'
const child = 'mark(<<"screen">>,<<"plane">>,[f(<<"width">>,1000),f(<<"height">>,600)],relative(<<"console">>,transform(0,0,-100,0,0,0)),pbr(<<"#F9C80E">>,0,900,700),unlabelled,depicts_nothing)'

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
    `[${root.replace('no_surface', 'material(<<"#FFFFFF">>,<<"matte">>)')}]`,
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
