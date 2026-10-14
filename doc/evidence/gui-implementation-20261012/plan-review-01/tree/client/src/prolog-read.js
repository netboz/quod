// The reading half of the frozen signed-goal text grammar: bindings come back
// from a signed read as Prolog text, and this turns that text back into terms.
// prolog-term.js renders; this reads. Neither one knows any predicate.
//
// Result values use functional notation, including variables in authored code.
// This reader does not interpret source operators or execute goals. Projection
// callers keep the stricter ground/proper-list contract through readList.

import { atom, binary, compound, list, number, variable } from './prolog-term.js'

import { PROLOG_TERM_LIMITS } from './protocol-limits.js'

const ATOM = /^[a-z][A-Za-z0-9_]*/
const VARIABLE = /^[A-Z_][A-Za-z0-9_]*/
const NUMBER = /^-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/

// Read exactly one term from one binding's text. Trailing content is an error
// rather than something quietly ignored. The transport owns reply admission;
// escaped source bytes are not the binary codec size and get no second budget.
export function readTerm(text) {
  if (typeof text !== 'string') throw new Error('a binding is not text')
  const state = { text, at: 0, variables: new Map() }
  const term = readOne(state, 0)
  skipSpace(state)
  if (state.at !== text.length) throw new Error('trailing text after the term')
  return term
}

// Projection data must remain ground and contain no discarded partial tails.
// Code callers use readTerm, since clauses intentionally contain variables.
export function readList(text) {
  const term = readTerm(text)
  if (term.type !== 'list') throw new Error('this binding is not a list')
  requireProjection(term)
  return term.items
}

function requireProjection(term) {
  if (term.type === 'variable') throw new Error('a projection must be ground')
  if (term.type === 'list') {
    if (term.tail !== null) throw new Error('a partial list is not a projection')
    term.items.forEach(requireProjection)
  } else if (term.type === 'compound') term.args.forEach(requireProjection)
}

function readOne(state, depth) {
  if (depth > PROLOG_TERM_LIMITS.depth) throw new Error('term too deeply nested')
  skipSpace(state)
  const rest = state.text.slice(state.at)
  if (rest.length === 0) throw new Error('the term ends early')
  if (rest.startsWith('<<')) return readBinary(state)
  if (rest.startsWith('[')) return readItems(state, depth)
  if (rest.startsWith("'")) return readQuotedAtom(state, depth)
  const numeric = NUMBER.exec(rest)
  if (numeric) {
    const literal = numeric[0]
    state.at += literal.length
    if (/[.eE]/.test(literal)) {
      const value = Number(literal)
      if (!Number.isFinite(value)) throw new Error('number out of range')
      // Keep 1.0 distinct from integer 1, and retain exact exponent spelling.
      return Object.freeze({ ...number(value), literal })
    }
    const integer = Number(literal)
    return number(Number.isSafeInteger(integer) ? integer : BigInt(literal))
  }
  const named = VARIABLE.exec(rest)
  if (named) {
    const name = named[0]
    state.at += name.length
    if (name === '_') return variable(name)
    if (!state.variables.has(name)) state.variables.set(name, variable(name))
    return state.variables.get(name)
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
    skipSpace(state)
    const next = state.text[state.at]
    if (next === ']') { state.at += 1; return list(items) }
    if (next === '|') {
      state.at += 1
      const tail = readOne(state, depth + 1)
      skipSpace(state)
      if (state.text[state.at] !== ']') throw new Error('expected ] after a list tail')
      state.at += 1
      return list(items, tail)
    }
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
    case 'b': return '\b'
    case 'f': return '\f'
    case 'v': return '\v'
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
