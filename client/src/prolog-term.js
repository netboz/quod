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
  return Object.is(value, -0) ? '-0.0' : String(value)
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

// Readable code uses the frozen operator priorities from
// quod_client_goal_parser. This is a printer, not another Prolog parser.
// renderTerm above retains the byte spelling used by signed request builders.
const INFIX = new Map([
  [':-', [1199, 1200, 1199]], ['-->', [1199, 1200, 1199]],
  [';', [1099, 1100, 1100]], ['->', [1049, 1050, 1050]],
  [',', [999, 1000, 1000]],
  ...['=', '\\=', '\\==', '==', '@<', '@=<', '@>', '@>=', '=..',
      'is', '=:=', '=\\=', '<', '=<', '>', '>='].map(op => [op, [699, 700, 699]]),
  [':', [599, 600, 600]], ['::', [649, 650, 649]],
  ...['+', '-', '/\\', '\\/'].map(op => [op, [500, 500, 499]]),
  ...['*', '/', '//', 'rem', 'mod', '<<', '>>'].map(op => [op, [400, 400, 399]]),
  ['**', [199, 200, 199]], ['^', [199, 200, 200]],
])
const PREFIX = new Map([
  ['?-', [1200, 1199]], [':-', [1200, 1199]], ['\\+', [900, 900]],
  ...['+', '-', '\\'].map(op => [op, [200, 200]]),
])

export function formatTerm(value) {
  return formatAt(value, 1200)
}

export function formatClause(value) {
  const text = formatTerm(value)
  // Keep a trailing graphic operator separate from the clause terminator.
  const separator = '-#$&*+./\\:<=>?@^~'.includes(text.at(-1)) ? ' ' : ''
  return `${text}${separator}.`
}

function formatAt(value, context) {
  if (!value || typeof value !== 'object') throw new Error('invalid Prolog term')
  if (value.type === 'number') {
    const text = formatNumber(value)
    return text.startsWith('-') ? `(${text})` : text
  }
  if (value.type === 'atom') {
    if (value.value === '!') return '!'
    if (value.value === '') return "''"
    return renderAtom(value.value)
  }
  if (value.type === 'list') {
    if (!Array.isArray(value.items) || (value.tail !== null && value.items.length === 0)) {
      throw new Error('invalid Prolog list')
    }
    return `[${value.items.map(item => formatAt(item, 999)).join(', ')}${
      value.tail === null ? '' : ` | ${formatAt(value.tail, 999)}`}]`
  }
  if (value.type !== 'compound') return renderTerm(value)
  const { functor, args } = value
  if (typeof functor !== 'string' || functor.length === 0 ||
      !Array.isArray(args) || args.length === 0) throw new Error('invalid Prolog compound')
  let text, priority
  if (args.length === 2 && INFIX.has(functor)) {
    const [left, current, right] = INFIX.get(functor)
    priority = current
    const separator = functor === ',' ? ', ' : ` ${functor} `
    text = `${formatAt(args[0], left)}${separator}${formatAt(args[1], right)}`
  } else if (args.length === 1 && PREFIX.has(functor)) {
    const [current, argument] = PREFIX.get(functor)
    priority = current
    text = `${functor} ${formatAt(args[0], argument)}`
  } else if (args.length === 1 && functor === '*') {
    priority = 400
    text = `${formatAt(args[0], 400)} *`
  } else {
    return `${renderFunctor(functor)}(${args.map(arg => formatAt(arg, 999)).join(', ')})`
  }
  return priority > context ? `(${text})` : text
}

function formatNumber(term) {
  if (term.literal !== undefined) {
    if (typeof term.literal !== 'string' ||
        !/^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$/.test(term.literal) ||
        !Number.isFinite(term.value) || !Object.is(Number(term.literal), term.value)) {
      throw new Error('invalid Prolog numeric literal')
    }
    return decimalExponent(term.literal)
  }
  return decimalExponent(renderNumber(term.value))
}

function decimalExponent(text) {
  // The frozen source grammar requires a decimal point before an exponent.
  return text.replace(/^(-?\d+)([eE])/, '$1.0$2')
}

// Wrap console input as one goal. Only its final full stop is moved; quoted
// content and comments are retained. Newlines keep trailing % comments from
// consuming the closing scope or terminator. The server remains the parser.
export function scopedGoal(agentNamespace, targetNamespace, source) {
  if (typeof source !== 'string' || !source.trim()) throw new Error('empty goal')
  let last = -1
  for (let at = 0; at < source.length;) {
    const c = source[at]
    if (/\s/.test(c)) { at++; continue }
    if (c === '%') {
      const end = source.indexOf('\n', at)
      at = end < 0 ? source.length : end + 1
      continue
    }
    if (source.startsWith('/*', at)) {
      const end = source.indexOf('*/', at + 2)
      if (end < 0) throw new Error('unterminated comment')
      at = end + 2
      continue
    }
    if (c === '"' || c === "'") {
      const quote = c
      at++
      for (;;) {
        if (at >= source.length) throw new Error('unterminated quoted value')
        if (source[at] === quote) { last = at++; break }
        if (source[at] === '\\') {
          if (source[at + 1] === 'x') {
            const end = source.indexOf('\\', at + 2)
            if (end < 0) throw new Error('unterminated hexadecimal escape')
            at = end + 1
          } else { at += 2 }
        } else { at++ }
      }
      continue
    }
    last = at++
  }
  if (last < 0) throw new Error('empty goal')
  const body = source[last] === '.' ? source.slice(0, last) + source.slice(last + 1) : source
  return agentNamespace === targetNamespace
    ? `${body}\n.`
    : `${renderTerm(atom(targetNamespace))} :: (\n${body}\n).`
}
