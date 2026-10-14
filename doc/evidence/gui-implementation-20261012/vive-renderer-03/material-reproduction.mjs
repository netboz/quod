import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { NullEngine } from '../../../../client/node_modules/@babylonjs/core/Engines/nullEngine.js'
import { Scene } from '../../../../client/node_modules/@babylonjs/core/scene.js'
import { NodeMaterial } from '../../../../client/node_modules/@babylonjs/core/Materials/Node/nodeMaterial.js'

const source = JSON.parse(await readFile(new URL('./touch-material.json', import.meta.url)))
const engine = new NullEngine()
const scene = new Scene(engine)
const before = new NodeMaterial('before', scene)
assert.throws(() => before.parseSerializedObject(source), /target/)
before.dispose()
await import('../../../../client/node_modules/@babylonjs/core/Materials/Node/Blocks/index.js')
const after = new NodeMaterial('after', scene)
after.parseSerializedObject(source)
assert.ok(after.attachedBlocks.length > 0)
await new Promise((resolve, reject) => {
  after.onBuildObservable.addOnce(resolve)
  after.onBuildErrorObservable.addOnce(reject)
  after.build()
})
console.log(JSON.stringify({ reproducedMissingRegistration: true,
  parsedAndBuiltWithRegistration: true, blocks: after.attachedBlocks.length }))
scene.dispose()
engine.dispose()
