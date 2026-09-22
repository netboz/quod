// The Babylon half of the adapter: marks become meshes.
//
// Applying a projection is idempotent: a mark still in the projection is
// replaced by its current descriptor, one that is gone is disposed, and
// painting the same marks twice leaves the same scene — so a reconnect or a
// refreshed read reconciles rather than accumulating. Mark identity drives
// create, update and remove; the domain entity a mark depicts is carried in the
// mesh's metadata, because selection resolves through the entity and never
// through a mesh name. Replacing rather than mutating is this slice's choice:
// it keeps one code path, and a mark whose descriptor is unchanged is cheap
// enough at a projection's bounded size.
//
// Descriptors are in millimetres and whole degrees. This is where they become
// the renderer's metres and radians, and the only place that conversion lives.

import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder'
import { StandardMaterial } from '@babylonjs/core/Materials/standardMaterial'
import { DynamicTexture } from '@babylonjs/core/Materials/Textures/dynamicTexture'
import { Color3 } from '@babylonjs/core/Maths/math.color'
import { Vector3 } from '@babylonjs/core/Maths/math.vector'

const MM = 1000
const DEGREES = Math.PI / 180
const LABEL_HEIGHT_MM = 220

// Paint `marks` into `scene`, reconciling against what a previous call left.
// Returns the painted set, to be handed back on the next call.
export function paintMarks(scene, marks, painted = new Map()) {
  const next = new Map()
  for (const mark of marks) {
    const existing = painted.get(mark.id)
    if (existing) existing.dispose(false, true)
    next.set(mark.id, paintOne(scene, mark))
  }
  for (const [id, mesh] of painted) {
    if (!next.has(id)) mesh.dispose(false, true)
  }
  return next
}

// Remove everything a previous paint left, leaving the rest of the scene alone.
export function clearMarks(painted) {
  for (const mesh of painted.values()) mesh.dispose(false, true)
  return new Map()
}

function paintOne(scene, mark) {
  const mesh = buildGeometry(scene, mark)
  const { x, y, z, rx, ry, rz } = mark.transform
  mesh.position = new Vector3(x / MM, y / MM, z / MM)
  mesh.rotation = new Vector3(rx * DEGREES, ry * DEGREES, rz * DEGREES)
  mesh.material = buildMaterial(scene, mark)
  // The subject, not the mesh name, is what a later selection resolves.
  mesh.metadata = { markId: mark.id, depicts: mark.depicts }
  if (mark.label) attachLabel(scene, mesh, mark)
  return mesh
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

function buildMaterial(scene, { id, material }) {
  const surface = new StandardMaterial(`mark-material:${id}`, scene)
  const colour = Color3.FromHexString(material.colour)
  surface.diffuseColor = colour
  surface.emissiveColor = colour.scale(emission(material.finish))
  surface.specularColor = material.finish === 'glossy'
    ? Color3.White().scale(0.4)
    : Color3.Black()
  return surface
}

function emission(finish) {
  if (finish === 'emissive') return 0.65
  if (finish === 'glossy') return 0.12
  return 0.2
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
                   mark.material.colour, 'transparent', true)
  const surface = new StandardMaterial(`mark-label-material:${mark.id}`, scene)
  surface.diffuseTexture = texture
  surface.emissiveTexture = texture
  surface.opacityTexture = texture
  surface.disableLighting = true
  plane.material = surface
  plane.billboardMode = 7 // BILLBOARDMODE_ALL: no import needed for a constant
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
