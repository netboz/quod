// The reading half of the frozen signed-goal text grammar: bindings come back
// from a signed read as Prolog text, and this turns that text back into terms.
// prolog-term.js renders; this reads. Neither one knows any predicate.
//
// It is deliberately small and deliberately strict. It accepts the shapes the
// reply renderer produces — compounds, lists, binaries, whole numbers, plain
// and quoted atoms — and throws on everything else, including the two lossy
// renderings a reply can contain: a 32-byte binary, which arrives as a key
// fingerprint rather than as data, and a binary with unprintable bytes, which
// arrives truncated. Failing there is the point: a descriptor that did not
// survive the wire must not be drawn as though it had.

const LIMITS = Object.freeze({
  text: 65536,
  nodes: 4096,
  depth: 32,
  items: 1024,
})

const ATOM = /^[a-z][A-Za-z0-9_]*/
const INTEGER = /^-?[0-9]+/

export const binary = value => Object.freeze({ type: 'binary', value })
export const atom = value => Object.freeze({ type: 'atom', value })
export const number = value => Object.freeze({ type: 'number', value })

export function compound(functor, args) {
  return Object.freeze({ type: 'compound', functor, args: Object.freeze(args) })
}

export function list(items) {
  return Object.freeze({ type: 'list', items: Object.freeze(items) })
}

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

// `<<"text">>` only. `<<0x…>>` is the renderer's shortened form for bytes it
// could not print, and a bare `kp_…` is its form for a 32-byte binary; neither
// carries the value, so neither is accepted here.
function readBinary(state) {
  if (!state.text.startsWith('<<"', state.at)) {
    throw new Error('this binary did not survive the reply intact')
  }
  state.at += 3
  let value = ''
  for (;;) {
    const character = state.text[state.at]
    if (character === undefined) throw new Error('unterminated binary')
    if (character === '"') {
      if (!state.text.startsWith('">>', state.at)) {
        throw new Error('unterminated binary')
      }
      state.at += 3
      return binary(value)
    }
    state.at += 1
    if (character === '\\') {
      value += unescape(state)
      continue
    }
    value += character
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
    default: throw new Error(`unsupported escape \\${character}`)
  }
}

function skipSpace(state) {
  while (state.at < state.text.length && /\s/.test(state.text[state.at])) {
    state.at += 1
  }
}
