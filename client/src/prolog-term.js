// Pure, predicate-neutral builders for the frozen signed-goal text grammar.
// They produce ordinary inspectable Prolog text; signedGoal remains the only
// request encoder and signer.

const VARIABLE = /^[A-Z_][A-Za-z0-9_]*$/u
const FUNCTOR = /^[a-z][A-Za-z0-9_]*$/u

export const atom = value => term('atom', value)
export const string = value => term('string', value)
export const binary = value => term('binary', value)
export const number = value => term('number', value)
export const variable = value => term('variable', value)

export function compound(functor, args = []) {
  if (typeof functor !== 'string' || functor.length === 0 ||
      !Array.isArray(args) || args.length === 0) {
    throw new Error('invalid Prolog compound')
  }
  return Object.freeze({ type: 'compound', functor, args: [...args] })
}

export function list(items, tail = null) {
  if (!Array.isArray(items) || (tail !== null && items.length === 0)) {
    throw new Error('invalid Prolog list')
  }
  return Object.freeze({ type: 'list', items: [...items], tail })
}

export function renderTerm(value) {
  if (!value || typeof value !== 'object') throw new Error('invalid Prolog term')
  switch (value.type) {
    case 'atom':
      return renderAtom(value.value)
    case 'string':
      if (typeof value.value !== 'string') throw new Error('invalid Prolog string')
      return `"${escapeQuoted(value.value, '"')}"`
    case 'binary':
      if (!(value.value instanceof Uint8Array)) throw new Error('invalid Prolog binary')
      return `<<"${escapeBinary(value.value)}">>`
    case 'number':
      return renderNumber(value.value)
    case 'variable':
      if (typeof value.value !== 'string' || !VARIABLE.test(value.value)) {
        throw new Error('invalid Prolog variable')
      }
      return value.value
    case 'compound':
      if (typeof value.functor !== 'string' || value.functor.length === 0 ||
          !Array.isArray(value.args) || value.args.length === 0) {
        throw new Error('invalid Prolog compound')
      }
      return `${renderFunctor(value.functor)}(${value.args.map(renderTerm).join(',')})`
    case 'list':
      if (!Array.isArray(value.items) ||
          (value.tail !== null && value.items.length === 0)) {
        throw new Error('invalid Prolog list')
      }
      return `[${value.items.map(renderTerm).join(',')}${
        value.tail === null ? '' : `|${renderTerm(value.tail)}`}]`
    default:
      throw new Error('invalid Prolog term')
  }
}

export function goalText(value) {
  return `${renderTerm(value)}.`
}

function term(type, value) {
  return Object.freeze({ type, value })
}

function renderAtom(value) {
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error('invalid Prolog atom')
  }
  return FUNCTOR.test(value) ? value : `'${escapeQuoted(value, "'")}'`
}

function renderFunctor(value) {
  return renderAtom(value)
}

function renderNumber(value) {
  if (typeof value === 'bigint') return value.toString(10)
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new Error('invalid Prolog number')
  }
  if (Number.isInteger(value) && !Number.isSafeInteger(value)) {
    throw new Error('unsafe Prolog integer')
  }
  return Object.is(value, -0) ? '0' : String(value)
}

function escapeQuoted(value, quote) {
  let result = ''
  for (const character of value) {
    switch (character) {
      case '\\': result += '\\\\'; break
      case '\n': result += '\\n'; break
      case '\r': result += '\\r'; break
      case '\t': result += '\\t'; break
      case '\b': result += '\\b'; break
      case '\f': result += '\\f'; break
      case '\v': result += '\\v'; break
      default:
        if (character === quote) result += `\\${character}`
        else if (character.codePointAt(0) < 0x20) {
          result += `\\x${character.codePointAt(0).toString(16)}\\`
        } else result += character
    }
  }
  return result
}

function escapeBinary(value) {
  let result = ''
  for (const byte of value) {
    switch (byte) {
      case 0x0a: result += '\\n'; break
      case 0x0d: result += '\\r'; break
      case 0x09: result += '\\t'; break
      case 0x22: result += '\\"'; break
      case 0x5c: result += '\\\\'; break
      default:
        if (byte >= 0x20 && byte <= 0x7e) result += String.fromCharCode(byte)
        else result += `\\x${byte.toString(16).padStart(2, '0')}\\`
    }
  }
  return result
}
