// One signed read's bindings become marks this client can draw.
//
// `quod:present` is the authority on what a descriptor may contain; this is the
// Babylon adapter's half of the contract — which renderer-neutral kind becomes
// which mesh, and which field name becomes which parameter. It recognises what
// it can draw and refuses everything else, so an unknown kind, an unknown
// field or a value that is not a whole number fails closed instead of being
// drawn as something it is not.
//
// Lengths stay in the millimetres the descriptor uses. Converting to the
// renderer's units happens where the mesh is built, not here.

import { readList } from './prolog-read.js'

// kind -> the fields it takes, in the order quod:present declares them.
const GEOMETRY = Object.freeze({
  box: ['width', 'height', 'depth'],
  sphere: ['diameter'],
  plane: ['width', 'height'],
  cylinder: ['diameter', 'height'],
})

const FINISHES = Object.freeze(['matte', 'glossy', 'emissive'])
const PLACEMENTS = Object.freeze(['above', 'centre', 'below'])
const COLOUR = /^#[0-9A-F]{6}$/

// Read one `Marks` binding into drawable marks. Throws on anything the
// vocabulary does not cover; a partly-understood scene is never returned.
export function readMarks(text) {
  const marks = readList(text).map(readMark)
  const ids = new Set(marks.map(mark => mark.id))
  if (ids.size !== marks.length) throw new Error('two marks share one identity')
  return marks
}

function readMark(term) {
  const [id, kind, size, transform, material, label, depicts] =
    args(term, 'mark', 7)
  const name = binaryValue(kind, 'mark kind')
  const fields = GEOMETRY[name]
  if (!fields) throw new Error(`this client cannot draw a ${name}`)
  return Object.freeze({
    id: binaryValue(id, 'mark id'),
    kind: name,
    size: readSize(size, fields),
    transform: readTransform(transform),
    material: readMaterial(material),
    label: readLabel(label),
    depicts: readDepicts(depicts),
  })
}

function readSize(term, fields) {
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
  })
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
  const [colour, finish] = args(term, 'material', 2)
  const hex = binaryValue(colour, 'a colour')
  if (!COLOUR.test(hex)) throw new Error(`${hex} is not a colour`)
  return Object.freeze({ colour: hex, finish: oneOf(finish, FINISHES, 'finish') })
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
  const [ontology, thing] = args(term, 'depicts', 2)
  return Object.freeze({
    ontology: binaryValue(ontology, 'an ontology name'),
    entity: thing,
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
  return term.value
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
