// Reconcile one ontology-derived scene. Stable occurrences retain their engine
// objects; parents compose local transforms. No domain state is stored here.

import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder.js'
import { StandardMaterial } from '@babylonjs/core/Materials/standardMaterial.js'
import { DynamicTexture } from '@babylonjs/core/Materials/Textures/dynamicTexture.js'
import { Color3 } from '@babylonjs/core/Maths/math.color.js'
import { Vector3, Quaternion } from '@babylonjs/core/Maths/math.vector.js'

import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js'
import { PBRMaterial } from '@babylonjs/core/Materials/PBR/pbrMaterial.js'

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
    const geometry = JSON.stringify([mark.kind, mark.size])
    let entry = painted.get(mark.id)
    if (entry && entry.geometry !== geometry) {
      retired.push(entry)
      entry = null
    }
    if (!entry) {
      const node = mark.kind === 'group'
        ? new TransformNode(`mark:${mark.id}`, scene)
        : buildGeometry(scene, mark)
      entry = { node, geometry, signature: null, label: null }
    }
    const signature = JSON.stringify(mark)
    if (entry.signature !== signature) {
      const { x, y, z, rx, ry, rz } = mark.transform
      entry.node.position.set(x / MM, y / MM, z / MM)
      entry.node.rotationQuaternion = Quaternion.RotationAxis(Vector3.Forward(), rz * DEGREES)
        .multiply(Quaternion.RotationAxis(Vector3.Up(), ry * DEGREES))
        .multiply(Quaternion.RotationAxis(Vector3.Right(), rx * DEGREES))
      entry.node.metadata = { markId: mark.id, depicts: mark.depicts }
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

export function clearMarks(painted) {
  for (const entry of painted.values()) disposeEntry(entry)
  return new Map()
}

function disposeEntry(entry) {
  entry.label?.dispose(false, true)
  entry.node.material?.dispose(false, false)
  entry.binding?.release()
  entry.node.dispose(true, false)
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
    default:
      // readMarks refuses an unknown kind, so reaching this is a bug here.
      throw new Error(`no mesh for ${kind}`)
  }
}

// The single neutral surface contract maps to Babylon's metallic/roughness
// material. Resource leases survive transform changes and unchanged refreshes.
function applyMaterial(scene, entry, { id, material }, resources, onError) {
  const mesh = entry.node
  const surface = mesh.material ?? new PBRMaterial(`mark-material:${id}`, scene)
  const colour = Color3.FromHexString(material.colour)
  surface.albedoColor = colour.toLinearSpace()
  surface.metallic = material.metallic
  surface.roughness = material.roughness
  surface.emissiveColor = surface.albedoColor.scale(material.emission)
  surface.albedoTexture = surface.bumpTexture = surface.metallicTexture = null
  // OpenGL tangent-space normal maps, matching the glTF adapter convention.
  surface.invertNormalMapX = !scene.useRightHandedSystem
  surface.invertNormalMapY = scene.useRightHandedSystem
  surface.useRoughnessFromMetallicTextureAlpha = false
  surface.useRoughnessFromMetallicTextureGreen = true
  surface.useMetallnessFromMetallicTextureBlue = true
  surface.useAmbientOcclusionFromMetallicTextureRed = true
  mesh.material = surface
  const leases = material.textures.map(binding => {
    if (!resources) throw new Error('textured surfaces require a render resource owner')
    return resources.acquire(binding)
  })
  // Acquire the replacement before releasing the old surface: shared assets
  // remain alive even when a different slot or tiling is selected.
  entry.binding?.release()
  let active = true
  entry.binding = { release() { active = false; leases.forEach(lease => lease.release()) } }
  mesh.isVisible = leases.length === 0
  if (!leases.length) return
  Promise.all(leases.map(lease => lease.ready)).then(textures => {
    if (!active) return
    const slots = { base_colour: 'albedoTexture', normal: 'bumpTexture', orm: 'metallicTexture' }
    textures.forEach((texture, i) => { surface[slots[material.textures[i].slot]] = texture })
    mesh.isVisible = true
  }).catch(error => {
    if (active) onError(new Error(`Cannot draw ${id}: ${error.message}`))
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
  const extent = (mark.size.height ?? mark.size.diameter ?? 0) / MM
  if (placement === 'above') return extent / 2 + LABEL_HEIGHT_MM / MM
  if (placement === 'below') return -(extent / 2 + LABEL_HEIGHT_MM / MM)
  return 0
}
