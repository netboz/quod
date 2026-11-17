// One signed read's bindings become marks this client can draw.
//
// `quod:gui` is the authority on what a descriptor may contain; this is the
// Babylon adapter's half of the contract — which renderer-neutral kind becomes
// which mesh, and which field name becomes which parameter. It recognises what
// it can draw and refuses everything else, so an unknown kind, an unknown
// field or a value that is not a whole number fails closed instead of being
// drawn as something it is not.
//
// Lengths stay in the millimetres the descriptor uses. Converting to the
// renderer's units happens where the mesh is built, not here.

import { readList } from './prolog-read.js'

// kind -> the fields it takes, in the order quod:gui declares them.
const GEOMETRY = Object.freeze({
  box: ['width', 'height', 'depth'],
  sphere: ['diameter'],
  plane: ['width', 'height'],
  cylinder: ['diameter', 'height'],
  capsule: ['diameter', 'height'],
  torus: ['diameter', 'thickness'],
  sky_sphere: ['diameter'],
  group: [],
  mesh: [],
  terrain: [],
})

const PLACEMENTS = Object.freeze(['above', 'centre', 'below'])
const COLOUR = /^#[0-9A-F]{6}$/

// Read one `Marks` binding into drawable marks. Throws on anything the
// vocabulary does not cover; a partly-understood scene is never returned.
export function readMarks(text) {
  const marks = readList(text).map(readMark)
  const ids = new Set(marks.map(mark => mark.id))
  if (ids.size !== marks.length) throw new Error('two marks share one identity')
  const seen = new Set()
  const horizons = new Set(marks.filter(mark => mark.kind === 'terrain').map(mark => JSON.stringify(mark.size.viewDistance)))
  if (horizons.size > 1) throw new Error('terrain view distances disagree')
  for (const mark of marks) {
    if (mark.parent !== null && !seen.has(mark.parent)) {
      throw new Error('a parent must precede its child')
    }
    seen.add(mark.id)
  }
  return marks
}

function readMark(term) {
  const [id, kind, size, transform, material, label, depicts] =
    args(term, 'mark', 7)
  const name = binaryValue(kind, 'mark kind')
  const fields = GEOMETRY[name]
  if (!fields) throw new Error(`this client cannot draw a ${name}`)
  const relative = transform.type === 'compound' && transform.functor === 'relative'
  const [parent, local] = relative ? args(transform, 'relative', 2) : [null, transform]
  const driven = local.type === 'compound' && local.functor === 'body_pose'
  const body = driven ? args(local, 'body_pose', 2).map((term, index) => {
    if (term.type !== 'number' || (typeof term.value !== 'bigint' && !Number.isSafeInteger(term.value)) ||
        BigInt(term.value) < BigInt(index) || BigInt(term.value) > 0xffffffffffffffffn) {
      throw new Error('invalid body identity or revision')
    }
    return String(term.value)
  }) : null
  const group = name === 'group'
  const mesh = name === 'mesh'
  const terrain = name === 'terrain'
  if (group && (material.type !== 'atom' || material.value !== 'no_surface')) {
    throw new Error('a group has no surface')
  }
  if (mesh && (material.type !== 'atom' || material.value !== 'asset_surfaces')) {
    throw new Error('a mesh uses its embedded asset surfaces')
  }
  const subject = readDepicts(depicts)
  if (terrain && (!body || !subject?.anchor || material.type !== 'atom' || material.value !== 'terrain_surfaces' ||
    label.type !== 'atom' || label.value !== 'unlabelled')) throw new Error('terrain requires an anchored body and generated surfaces')
  return Object.freeze({
    id: binaryValue(id, 'mark id'),
    kind: name,
    size: terrain ? readTerrain(size) : mesh ? readMesh(size) : readSize(size, fields, name),
    parent: parent === null ? null : binaryValue(parent, 'parent id'),
    transform: driven ? null : readTransform(local),
    ...(body ? { body: Object.freeze({ id: body[0], revision: body[1] }) } : {}),
    material: group || mesh || terrain ? null : readMaterial(material),
    label: readLabel(label),
    depicts: subject,
  })
}

function allowance(term) {
  return term?.type === 'atom' && term.value === 'unlimited' ? Infinity : whole(term, 'resource allowance')
}

function readTerrain(term) {
  const [profile, palette, view, resources] = args(term, 'terrain_geometry', 4)
  oneOf(profile, ['qvt1'], 'terrain profile')
  if (palette.type !== 'list' || palette.tail !== null || !palette.items.length) throw new Error('invalid terrain palette')
  let previous = -1
  const materials = palette.items.map(item => {
    const [id, surface] = args(item, 'material', 2), value = whole(id, 'material identity')
    if (value <= previous || value > 65535) throw new Error('invalid terrain material identity')
    previous = value
    return Object.freeze([value, readMaterial(surface)])
  })
  const limits = args(resources, 'resources', 5).map(allowance)
  if (limits.some(n => n <= 0)) throw new Error('invalid terrain allowance')
  const viewDistance = args(view, 'view_distance', 3).map(n => whole(n, 'view distance'))
  if (viewDistance[0] <= 0 || viewDistance[1] <= 0 || viewDistance[2] < viewDistance[1] ||
      !Number.isSafeInteger(viewDistance[0] + viewDistance[2])) throw new Error('invalid view distance')
  return Object.freeze({ profile: 'qvt1', palette: Object.freeze(materials),
    viewDistance: Object.freeze(viewDistance),
    allowed: Object.freeze(limits.slice(0, 4)), chunks: limits[4] })
}

function readMesh(term) {
  const [asset, profile, scale, frame, resources] = args(term, 'mesh_asset', 5)
  const [hash, mime] = args(asset, 'asset', 2)
  const digest = binaryValue(hash, 'mesh digest')
  if (!/^[0-9a-f]{64}$/.test(digest)) throw new Error('invalid mesh SHA-256')
  oneOf(mime, ['model/gltf-binary'], 'mesh media type')
  oneOf(profile, ['gltf2-static-v1'], 'mesh profile')
  const [factor] = args(scale, 'scale', 1)
  const permille = whole(factor, 'mesh scale')
  if (permille <= 0) throw new Error('invalid mesh scale')
  const [box, pivot, facing] = args(frame, 'frame', 3)
  const bounds = args(box, 'aabb', 6).map(n => whole(n, 'asset bound'))
  if (bounds.some((n, i) => i < 3 && n >= bounds[i + 3])) throw new Error('invalid asset bounds')
  const origin = args(pivot, 'pivot', 3).map(n => whole(n, 'asset pivot'))
  const [direction] = args(facing, 'front', 1)
  const front = oneOf(direction, ['-z', '+z', '+x', '-x'], 'asset front')
  const allowed = args(resources, 'resources', 7).map(allowance)
  if (allowed.some(n => n <= 0)) throw new Error('invalid mesh allowance')
  return Object.freeze({ digest, profile: 'gltf2-static-v1', scale: permille / 1000,
    bounds: Object.freeze(bounds), pivot: Object.freeze(origin), front,
    allowed: Object.freeze(allowed) })
}

function readSize(term, fields, kind) {
  if (term.type !== 'list' || term.items.length !== fields.length) {
    throw new Error('a mark carries the wrong number of dimensions')
  }
  const size = {}
  term.items.forEach((item, at) => {
    const [field, extent] = args(item, 'f', 2)
    const named = binaryValue(field, 'dimension')
    if (named !== fields[at]) {
      throw new Error(`expected ${fields[at]} and found ${named}`)
    }
    size[named] = whole(extent, 'a dimension')
    if (size[named] <= 0) throw new Error('a dimension must be positive')
  })
  if (kind === 'capsule' && size.height < size.diameter) {
    throw new Error('a capsule height must include both rounded ends')
  }
  if (kind === 'torus' && size.thickness >= size.diameter) {
    throw new Error('a torus thickness must be smaller than its diameter')
  }
  return Object.freeze(size)
}

function readTransform(term) {
  const [x, y, z, rx, ry, rz] = args(term, 'transform', 6)
  return Object.freeze({
    x: whole(x, 'a position'),
    y: whole(y, 'a position'),
    z: whole(z, 'a position'),
    rx: whole(rx, 'a rotation'),
    ry: whole(ry, 'a rotation'),
    rz: whole(rz, 'a rotation'),
  })
}

function readMaterial(term) {
  const [colour, metallic, roughness, emission, opacity, bindings] = args(term, 'surface', 6)
  if (bindings.type !== 'list' || bindings.tail !== null) throw new Error('expected texture bindings')
  const slots = new Set()
  const textures = bindings.items.map(binding => {
    const [slotTerm, asset, tiling] = args(binding, 'texture', 3)
    const slot = oneOf(slotTerm, ['base_colour', 'normal', 'orm'], 'texture slot')
    if (slots.has(slot)) throw new Error('duplicate texture slot')
    slots.add(slot)
    const digest = readImageAsset(asset)
    const [u, v] = args(tiling, 'repeat', 2)
    const repeat = [u, v].map(value => {
      const n = whole(value, 'texture repeat')
      if (n <= 0) throw new Error('texture repeat must be positive')
      return n / 1000
    })
    return Object.freeze({ slot, digest, repeat: Object.freeze(repeat) })
  })
  return Object.freeze({ colour: readColour(colour), metallic: fraction(metallic),
    roughness: fraction(roughness), emission: fraction(emission), opacity: fraction(opacity), textures: Object.freeze(textures) })
}

export function readImageAsset(asset) {
  const [hash, mime] = args(asset, 'asset', 2)
  const digest = binaryValue(hash, 'texture digest')
  if (!/^[0-9a-f]{64}$/.test(digest)) throw new Error('invalid texture SHA-256')
  oneOf(mime, ['image/png', 'image/jpeg'], 'image media type')
  return digest
}

function readColour(colour) {
  const hex = binaryValue(colour, 'a colour')
  if (!COLOUR.test(hex)) throw new Error(`${hex} is not a colour`)
  return hex
}

function fraction(term) {
  const n = whole(term, 'a material factor')
  if (n < 0 || n > 1000) throw new Error('a material factor must be between 0 and 1000')
  return n / 1000
}

function readLabel(term) {
  if (term.type === 'atom' && term.value === 'unlabelled') return null
  const [text, placement] = args(term, 'label', 2)
  return Object.freeze({
    text: binaryValue(text, 'label text'),
    placement: oneOf(placement, PLACEMENTS, 'label placement'),
  })
}

// A mark that shows a domain thing names the ontology and the ground term that
// identifies it there. The term is kept as read: selection resolves through it,
// never through a mesh name.
function readDepicts(term) {
  if (term.type === 'atom' && term.value === 'depicts_nothing') return null
  const anchored = term?.args?.length === 3
  const values = args(term, 'depicts', anchored ? 3 : 2)
  const [ontology] = values
  const anchor = anchored ? values[1] : null
  if (anchor !== null && (anchor.type !== 'binary' || anchor.value.length !== 32)) {
    throw new Error('an ontology anchor must contain 32 bytes')
  }
  return Object.freeze({
    ontology: binaryValue(ontology, 'an ontology name'),
    anchor: anchor?.value ?? null,
    entity: values.at(-1),
  })
}

function args(term, functor, arity) {
  if (term?.type !== 'compound' || term.functor !== functor ||
      term.args.length !== arity) {
    throw new Error(`expected ${functor}/${arity}`)
  }
  return term.args
}

function binaryValue(term, what) {
  if (term?.type !== 'binary') throw new Error(`${what} is not text`)
  if (term.value.length === 0) throw new Error(`${what} is empty`)
  return new TextDecoder('utf-8', { fatal: true }).decode(term.value)
}

function whole(term, what) {
  if (term?.type !== 'number' || !Number.isInteger(term.value)) {
    throw new Error(`${what} is not a whole number`)
  }
  return term.value
}

function oneOf(term, allowed, what) {
  const value = binaryValue(term, what)
  if (!allowed.includes(value)) throw new Error(`${value} is not a ${what}`)
  return value
}
