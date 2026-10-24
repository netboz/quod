// Reconcile one ontology-derived scene. Stable occurrences retain their engine
// objects; parents compose local transforms. No domain state is stored here.

import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder.js'
import { Mesh } from '@babylonjs/core/Meshes/mesh.js'
import { CreateCapsule } from '@babylonjs/core/Meshes/Builders/capsuleBuilder.js'
import { CreateTorus } from '@babylonjs/core/Meshes/Builders/torusBuilder.js'
import { StandardMaterial } from '@babylonjs/core/Materials/standardMaterial.js'
import { DynamicTexture } from '@babylonjs/core/Materials/Textures/dynamicTexture.js'
import { Vector3, Quaternion, Matrix } from '@babylonjs/core/Maths/math.vector.js'

import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js'
import { createSurface } from './render-resources.js'

import { PALETTE } from './palette.js'

const MM = 1000
const DEGREES = Math.PI / 180
const LABEL_HEIGHT_MM = 220

// Entries own only rendering resources. Reparent surviving nodes before disposing
// removed parents, so removing a group cannot accidentally remove a kept child.
export function paintMarks(scene, marks, painted = new Map(), resources, onError = () => {}) {
  const next = new Map()
  const retired = []
  for (const mark of marks) {
    const geometry = mark.kind === 'mesh'
      ? JSON.stringify([mark.kind, mark.size.digest, mark.size.profile,
        mark.size.allowed, mark.size.bounds])
      : JSON.stringify([mark.kind, mark.size])
    let entry = painted.get(mark.id)
    if (entry && entry.geometry !== geometry) {
      retired.push(entry)
      entry = null
    }
    if (!entry) {
      const node = ['group', 'mesh', 'terrain'].includes(mark.kind)
        ? new TransformNode(`mark:${mark.id}`, scene)
        : buildGeometry(scene, mark)
      entry = { node, geometry, signature: null, label: null }
      if (mark.kind === 'mesh') attachModel(scene, entry, mark, resources, onError)
    }
    const signature = JSON.stringify(mark, (_, value) => typeof value === 'bigint' ? `${value}n` : value)
    if (entry.signature !== signature) {
      if (!mark.body) {
        const { x, y, z, rx, ry, rz } = mark.transform
        entry.node.position.set(x / MM, y / MM, z / MM)
        entry.node.rotationQuaternion = Quaternion.RotationAxis(Vector3.Forward(), rz * DEGREES)
          .multiply(Quaternion.RotationAxis(Vector3.Up(), ry * DEGREES))
          .multiply(Quaternion.RotationAxis(Vector3.Right(), rx * DEGREES))
      }
      if (JSON.stringify(entry.body) !== JSON.stringify(mark.body)) entry.node.setEnabled(!mark.body)
      entry.body = mark.body
      entry.terrain = mark.kind === 'terrain' ? mark.size : null
      entry.node.metadata = { markId: mark.id, depicts: mark.depicts }
      if (mark.kind === 'mesh') updateModelFrame(entry, mark.size)
      if (mark.material && entry.surfaceSignature !== JSON.stringify(mark.material)) {
        applyMaterial(scene, entry, mark, resources, onError)
        entry.surfaceSignature = JSON.stringify(mark.material)
      }
      const labelSignature = JSON.stringify([mark.label, mark.size, mark.material?.colour])
      if (entry.labelSignature !== labelSignature) {
        entry.label?.dispose(false, true)
        entry.label = mark.label ? attachLabel(scene, entry.node, mark) : null
        entry.labelSignature = labelSignature
      }
      entry.signature = signature
    }
    entry.node.parent = mark.parent === null ? null : next.get(mark.parent).node
    next.set(mark.id, entry)
  }
  for (const [id, entry] of painted) {
    if (!next.has(id)) retired.push(entry)
  }
  for (const entry of retired) disposeEntry(entry)
  return next
}

// Poses use metres and world-space XYZW quaternions. Preserve authored parents
// by expressing a body's world pose in its parent's current frame. Marks are
// ordered parent-first, so attached decoration follows the same pose writer.
export function paintBodyPoses(painted, poses) {
  for (const entry of painted.values()) {
    if (!entry.body) continue
    const pose = poses.get(`${entry.body.id}:${entry.body.revision}`)
    entry.node.setEnabled(Boolean(pose))
    if (!pose) continue
    entry.node.position.set(...pose.position)
    entry.node.rotationQuaternion = new Quaternion(...pose.rotation)
    if (entry.node.parent) {
      const world = Matrix.Compose(Vector3.One(), entry.node.rotationQuaternion, entry.node.position)
      const inverseParent = entry.node.parent.computeWorldMatrix(true).clone().invert()
      world.multiply(inverseParent).decompose(entry.node.scaling, entry.node.rotationQuaternion, entry.node.position)
    }
  }
}

// Terrain is an ordinary body-bound mark whose children lease immutable models
// from the shared render owner. Eviction releases instances before allocation.
export function paintTerrain(scene, painted, current, resources, onError = () => {}) {
  const pending = []
  for (const entry of painted.values()) {
    if (!entry.terrain) continue
    if (!current || current.terrain === null) { entry.node.setEnabled(false); continue }
    entry.chunks ??= new Map()
    const rows = new Map([...(current?.terrain?.entries() ?? [])].filter(([, row]) =>
      row.body === entry.body.id && row.revision === entry.body.revision))
    for (const [id, chunk] of entry.chunks) {
      if (rows.get(id)?.digest !== chunk.digest) {
        disposeEntry(chunk); entry.chunks.delete(id)
      }
    }
    for (const [id, row] of rows) {
      let chunk = entry.chunks.get(id)
      if (!chunk) {
        const node = new TransformNode(`terrain:${id}`, scene)
        node.parent = entry.node
        chunk = { node, digest: row.digest }
        entry.chunks.set(id, chunk)
        const extent = row.spacing_mm * 8
        const palette = new Map(entry.terrain.palette)
        attachModel(scene, chunk, { id, size: { profile: 'qvt1', digest: row.digest,
          allowed: row.costs.slice(0, 4), bounds: [0, 0, 0, extent, extent, extent],
          palette, payload: row.payload, originMm: row.origin_mm } }, resources, onError, true)
      }
      chunk.node.position.set(...row.origin_mm.map((n, axis) => Number(BigInt(n) - current.origin[axis]) / MM))
      pending.push(chunk.ready)
    }
    entry.node.setEnabled(current?.terrainReady === true &&
      current.poses.has(`${entry.body.id}:${entry.body.revision}`))
  }
  return Promise.all(pending).then(() => undefined)
}

export function clearMarks(painted) {
  for (const entry of painted.values()) disposeEntry(entry)
  return new Map()
}

function disposeEntry(entry) {
  for (const chunk of entry.chunks?.values() ?? []) disposeEntry(chunk)
  entry.chunks?.clear()
  entry.label?.dispose(false, true)
  entry.node.material?.dispose(false, false)
  const model = entry.model
  entry.model = null
  entry.instance?.dispose()
  model?.release()
  entry.modelFrame?.dispose(false, false)
  entry.node.dispose(true, false)
}

function attachModel(scene, entry, mark, resources, onError, propagate = false) {
  if (!resources) throw new Error('mesh assets require a render resource owner')
  const frame = new TransformNode(`asset-frame:${mark.id}`, scene)
  frame.parent = entry.node
  entry.modelFrame = frame
  const lease = resources.acquireModel(mark.size)
  entry.model = lease
  entry.ready = lease.ready.then(container => {
    if (!container || entry.model !== lease) return
    const instance = container.instantiateModelsToScene(name => `asset:${mark.id}:${name}`)
    if (entry.model !== lease) { instance.dispose(); return }
    for (const root of instance.rootNodes) {
      // glTF names/extras are presentation data, never an interactive subject.
      root.getDescendants(false).concat(root).forEach(node => { node.metadata = null })
      root.parent = frame
    }
    entry.instance = instance
  }).catch(error => {
    if (entry.model === lease) {
      onError(new Error(`Cannot draw ${mark.id}: ${error.message}`))
      if (propagate) throw error
    }
  })
}

function updateModelFrame(entry, size) {
  const yaw = { '-z': 0, '+z': Math.PI, '+x': Math.PI / 2,
    '-x': -Math.PI / 2 }[size.front]
  entry.modelFrame.rotationQuaternion = Quaternion.RotationAxis(Vector3.Up(), yaw)
  entry.modelFrame.scaling.setAll(size.scale)
  const [x, y, z] = size.pivot
  entry.modelFrame.position.set(
    -(Math.cos(yaw) * x + Math.sin(yaw) * z) * size.scale / MM,
    -y * size.scale / MM,
    -(-Math.sin(yaw) * x + Math.cos(yaw) * z) * size.scale / MM)
}

function buildGeometry(scene, { id, kind, size }) {
  const name = `mark:${id}`
  switch (kind) {
    case 'box':
      return MeshBuilder.CreateBox(name, {
        width: size.width / MM, height: size.height / MM, depth: size.depth / MM,
      }, scene)
    case 'sphere':
      return MeshBuilder.CreateSphere(name, {
        diameter: size.diameter / MM, segments: 24,
      }, scene)
    case 'plane':
      return MeshBuilder.CreatePlane(name, {
        width: size.width / MM, height: size.height / MM,
      }, scene)
    case 'cylinder':
      return MeshBuilder.CreateCylinder(name, {
        diameter: size.diameter / MM, height: size.height / MM, tessellation: 24,
      }, scene)
    case 'capsule':
      return CreateCapsule(name, {
        radius: size.diameter / (2 * MM), height: size.height / MM, tessellation: 24,
      }, scene)
    case 'torus':
      return CreateTorus(name, {
        diameter: size.diameter / MM, thickness: size.thickness / MM, tessellation: 32,
      }, scene)
    case 'sky_sphere': {
      const sky = MeshBuilder.CreateSphere(name, {
        diameter: size.diameter / MM, segments: 48, sideOrientation: Mesh.BACKSIDE,
      }, scene)
      sky.isPickable = false
      return sky
    }
    default:
      // readMarks refuses an unknown kind, so reaching this is a bug here.
      throw new Error(`no mesh for ${kind}`)
  }
}

// The single neutral surface contract maps to Babylon's metallic/roughness
// material. Resource leases survive transform changes and unchanged refreshes.
function applyMaterial(scene, entry, { id, kind, material }, resources, onError) {
  const mesh = entry.node, previous = mesh.material
  const binding = createSurface(scene, `mark-material:${id}`, material, resources, kind === 'sky_sphere')
  // Acquire first, so common texture assets survive a surface replacement.
  mesh.material = binding.material
  previous?.dispose(false, false)
  mesh.isVisible = material.textures.length === 0
  binding.ready.then(surface => {
    if (surface && mesh.material === surface && !mesh.isDisposed()) mesh.isVisible = true
  }).catch(error => {
    if (!mesh.isDisposed() && mesh.material === binding.material) {
      onError(new Error(`Cannot draw ${id}: ${error.message}`))
    }
  })
}

// A label is display text on its mark. It is drawn as a billboarded plane so it
// stays readable from wherever the camera is, and it is parented to the mesh so
// disposing the mark disposes its label with it.
function attachLabel(scene, mesh, mark) {
  const { text, placement } = mark.label
  const height = LABEL_HEIGHT_MM / MM
  const width = height * Math.max(4, text.length * 0.62)
  const plane = MeshBuilder.CreatePlane(`mark-label:${mark.id}`, { width, height }, scene)
  const texture = new DynamicTexture(
    `mark-label-texture:${mark.id}`,
    { width: 64 * Math.ceil(width / height), height: 64 },
    scene,
    false,
  )
  texture.hasAlpha = true
  texture.drawText(text, null, 46, 'bold 40px system-ui, sans-serif',
                   mark.material?.colour ?? PALETTE.greyBlue, 'transparent', true)
  const surface = new StandardMaterial(`mark-label-material:${mark.id}`, scene)
  surface.diffuseTexture = texture
  surface.emissiveTexture = texture
  surface.opacityTexture = texture
  surface.disableLighting = true
  plane.material = surface
  plane.billboardMode = 7 // BILLBOARDMODE_ALL
  plane.parent = mesh
  plane.position = new Vector3(0, labelOffset(mark, placement), 0)
  plane.isPickable = false
  return plane
}

// The offset is in the mark's own local space, so a mark's own size decides
// where "above" and "below" are.
function labelOffset(mark, placement) {
  if (mark.kind === 'mesh') {
    const { bounds, pivot, scale } = mark.size
    if (placement === 'above') return (bounds[4] - pivot[1]) * scale / MM + LABEL_HEIGHT_MM / MM
    if (placement === 'below') return (bounds[1] - pivot[1]) * scale / MM - LABEL_HEIGHT_MM / MM
    return ((bounds[1] + bounds[4]) / 2 - pivot[1]) * scale / MM
  }
  const extent = (mark.size.height ?? mark.size.diameter ?? 0) / MM
  if (placement === 'above') return extent / 2 + LABEL_HEIGHT_MM / MM
  if (placement === 'below') return -(extent / 2 + LABEL_HEIGHT_MM / MM)
  return 0
}
