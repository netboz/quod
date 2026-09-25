// The reading half of the frozen signed-goal text grammar: bindings come back
// from a signed read as Prolog text, and this turns that text back into terms.
// prolog-term.js renders; this reads. Neither one knows any predicate.
//
// Projection reads are ground data. Reuse the request term representation so
// a selected exact identity can be put into another signed goal without a
// display-name or byte conversion. Result numbers may be negative literals;
// this reader does not interpret goal expressions or execute operators.

import { atom, binary, compound, list, number } from './prolog-term.js'

const LIMITS = Object.freeze({
  text: 65536,
  nodes: 4096,
  depth: 32,
  items: 1024,
})

const ATOM = /^[a-z][A-Za-z0-9_]*/
const INTEGER = /^-?[0-9]+/

// Read exactly one term from one binding's text. Trailing content is an error
// rather than something quietly ignored.
export function readTerm(text) {
  if (typeof text !== 'string') throw new Error('a binding is not text')
  if (text.length > LIMITS.text) throw new Error('binding too large')
  const state = { text, at: 0, nodes: 0 }
  const term = readOne(state, 0)
  skipSpace(state)
  if (state.at !== text.length) throw new Error('trailing text after the term')
  return term
}

// Convenience for a list-valued binding, which is what a bounded projection is.
export function readList(text) {
  const term = readTerm(text)
  if (term.type !== 'list') throw new Error('this binding is not a list')
  return term.items
}

function readOne(state, depth) {
  if (depth > LIMITS.depth) throw new Error('term too deeply nested')
  if (++state.nodes > LIMITS.nodes) throw new Error('term has too many parts')
  skipSpace(state)
  const rest = state.text.slice(state.at)
  if (rest.length === 0) throw new Error('the term ends early')
  if (rest.startsWith('<<')) return readBinary(state)
  if (rest.startsWith('[')) return readItems(state, depth)
  if (rest.startsWith("'")) return readQuotedAtom(state, depth)
  const integer = INTEGER.exec(rest)
  if (integer) {
    state.at += integer[0].length
    const value = Number(integer[0])
    if (!Number.isSafeInteger(value)) throw new Error('number out of range')
    return number(value)
  }
  const name = ATOM.exec(rest)
  if (!name) throw new Error(`cannot read a term at ${state.at}`)
  state.at += name[0].length
  return readCallOrAtom(state, name[0], depth)
}

function readCallOrAtom(state, name, depth) {
  if (state.text[state.at] !== '(') return atom(name)
  state.at += 1
  const args = []
  for (;;) {
    args.push(readOne(state, depth + 1))
    if (args.length > LIMITS.items) throw new Error('too many arguments')
    skipSpace(state)
    const next = state.text[state.at]
    if (next === ')') { state.at += 1; return compound(name, args) }
    if (next !== ',') throw new Error('expected , or ) in an argument list')
    state.at += 1
  }
}

function readQuotedAtom(state, depth) {
  state.at += 1
  let value = ''
  for (;;) {
    const character = state.text[state.at]
    if (character === undefined) throw new Error('unterminated quoted atom')
    state.at += 1
    if (character === "'") break
    if (character === '\\') {
      value += unescape(state)
      continue
    }
    value += character
  }
  return readCallOrAtom(state, value, depth) // 'quod:licence'(…) is a call too
}

function readItems(state, depth) {
  state.at += 1
  skipSpace(state)
  if (state.text[state.at] === ']') { state.at += 1; return list([]) }
  const items = []
  for (;;) {
    items.push(readOne(state, depth + 1))
    if (items.length > LIMITS.items) throw new Error('list too long')
    skipSpace(state)
    const next = state.text[state.at]
    if (next === ']') { state.at += 1; return list(items) }
    if (next === '|') throw new Error('a partial list is not a projection')
    if (next !== ',') throw new Error('expected , or ] in a list')
    state.at += 1
  }
}

// Byte escapes retain anchors, hashes and arbitrary binary values exactly.
function readBinary(state) {
  if (!state.text.startsWith('<<"', state.at)) {
    throw new Error('this binary did not survive the reply intact')
  }
  state.at += 3
  const bytes = []
  for (;;) {
    const character = state.text[state.at]
    if (character === undefined) throw new Error('unterminated binary')
    if (character === '"') {
      if (!state.text.startsWith('">>', state.at)) throw new Error('unterminated binary')
      state.at += 3
      return binary(Uint8Array.from(bytes))
    }
    state.at += 1
    const value = character === '\\' ? unescape(state) : character
    const code = value.codePointAt(0)
    if (code > 255) throw new Error('a byte escape is out of range')
    bytes.push(code)
  }
}

function unescape(state) {
  const character = state.text[state.at]
  if (character === undefined) throw new Error('the term ends inside an escape')
  state.at += 1
  switch (character) {
    case '"': return '"'
    case "'": return "'"
    case '\\': return '\\'
    case 'n': return '\n'
    case 'r': return '\r'
    case 't': return '\t'
    case 'x': {
      const match = /^[0-9a-fA-F]+\\/.exec(state.text.slice(state.at))
      if (!match) throw new Error('invalid hexadecimal escape')
      state.at += match[0].length
      const code = Number.parseInt(match[0].slice(0, -1), 16)
      if (code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) {
        throw new Error('invalid escaped character')
      }
      return String.fromCodePoint(code)
    }
    default: throw new Error(`unsupported escape \\${character}`)
  }
}

function skipSpace(state) {
  while (state.at < state.text.length && /\s/.test(state.text[state.at])) {
    state.at += 1
  }
}
