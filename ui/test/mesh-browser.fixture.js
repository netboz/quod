import { Engine } from '@babylonjs/core/Engines/engine.js'
import { Scene } from '@babylonjs/core/scene.js'
import { UniversalCamera } from '@babylonjs/core/Cameras/universalCamera.js'
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js'
import { createRenderResources } from '../../client/src/render-resources.js'
import { paintMarks, clearMarks } from '../../client/src/scene.js'

const query = new URLSearchParams(location.search)
const digest = query.get('digest') ??
  'ad1f1cbe8c100fd774e315b629d0bb1082820c9a7abe2a2a999aef846d675064'
const imageSize = Number(query.get('imageSize') ?? 2)
const bounds = imageSize === 2048 ? [-921, -929, -898, 881, 904, 894]
  : [-300, 0, -400, 1200, 1400, 300]
const size = { digest, profile: 'gltf2-static-v1', bounds,
  pivot: imageSize === 2048 ? [0, -929, 0] : [200, 0, -100],
  front: imageSize === 2048 ? '-z' : '+x', scale: 1,
  allowed: [8000000, 16000000, 250000, 250000, 1024, 256, 16000000] }
const transform = (x, ry) => ({ x, y: 0, z: 0, rx: 0, ry, rz: 0 })
const subject = id => ({ ontology: 'world', anchor: 'fixture-anchor', term: `entity(${id})` })
const marks = ['one', 'two'].flatMap((id, i) => [
  { id, kind: 'group', parent: null, size: [], transform: transform(i ? 2000 : -1000,
    i ? 270 : 90), material: null, label: null, depicts: subject(id) },
  { id: `${id}/asset`, kind: 'mesh', parent: id, size, transform: transform(0, 0),
    material: null, label: null, depicts: null },
])

window.meshResult = (async () => {
  const engine = new Engine(document.getElementById('scene'), true)
  const scene = new Scene(engine)
  scene.useRightHandedSystem = true
  const camera = new UniversalCamera('check', new Vector3(0, 1, -3), scene)
  camera.setTarget(new Vector3(0, 0.5, 0))
  let fetches = 0
  const resources = createRenderResources(scene, {
    fetchAsset: (url, options) => { fetches++; return fetch(url, options) },
  })
  let painted = new Map()
  try {
    painted = paintMarks(scene, marks, painted, resources)
    const entries = ['one/asset', 'two/asset'].map(id => painted.get(id))
    const templates = await Promise.all(entries.map(entry => entry.model.ready))
    await Promise.resolve()
    scene.render()
    const textureInfo = templates[0].textures.map(texture => ({
      size: texture.getSize(), ready: texture.isReady(), name: texture.name,
    }))
    const images = textureInfo.filter(texture => texture.size.width === imageSize &&
      texture.size.height === imageSize)
    const roots = entries.map(entry => entry.instance.rootNodes[0])
    const pickedSubjects = roots.map(root => {
      let node = root.getChildMeshes()[0]
      while (node && !node.metadata?.depicts) node = node.parent
      return node?.metadata?.depicts?.term
    })
    return { occurrences: entries.length, sharedTemplate: templates[0] === templates[1],
      fetches, distinctRoots: roots[0] !== roots[1],
      distinctTransforms: entries[0].node.getAbsolutePosition().x !==
        entries[1].node.getAbsolutePosition().x,
      pickedSubjects, importedMetadataCleared: roots.every(root =>
        [root, ...root.getDescendants(false)].every(node => node.metadata === null)),
      meshes: roots.flatMap(root => root.getChildMeshes()).length,
      materials: scene.materials.length, embeddedImages: images.length,
      textureReady: images.some(image => image.ready), textureInfo }
  } finally {
    clearMarks(painted)
    resources.dispose()
    scene.dispose()
    engine.dispose()
  }
})()
