import { readTerm, readList } from './prolog-read.js'
import { list, renderTerm } from './prolog-term.js'

// Presentation checks only. The ontology remains the submission authority.
export function numericControlRange({ min, max, step } = {}) {
  if (![min, max, step].every(Number.isSafeInteger) || min > max || step <= 0 ||
      !Number.isSafeInteger(max - min)) throw new Error('Unsupported numeric range')
  return { min, max, step, last: min + Math.floor((max - min) / step) * step }
}

export function numericDraft(range, text) {
  const { min, last, step } = range
  const value = Number(text)
  return typeof text === 'string' && /^-?\d+$/.test(text) && Number.isSafeInteger(value) &&
    value >= min && value <= last && (value - min) % step === 0 ? value : null
}

export function textFeedback(field, value) {
  const length = new TextEncoder().encode(value).length
  return field.required && !length ? 'This field is required.'
    : field.maxBytes !== undefined && length > field.maxBytes ? `${length} bytes; maximum ${field.maxBytes}.` : ''
}

// Concrete controls share typed draft conversion; presentation never grants
// authority. The ontology independently validates the submitted field set.
export function guiValueKind(kind) {
  if (['text_box', 'text_area'].includes(kind)) return 'text'
  if (['slider', 'rotary_knob', 'number_input'].includes(kind)) return 'number'
  if (['checkbox', 'toggle'].includes(kind)) return 'boolean'
  if (['selection', 'radio_group', 'selectable_list', 'table'].includes(kind)) return 'choice'
  return null
}

export function choiceValues(field, draft) {
  let values
  if (field.multiple) {
    // Invalid local drafts are visible validation failures, never executable
    // text or an implicit substitution of the previous accepted selection.
    try {
      values = readList(draft).map(renderTerm)
    } catch { return null }
  } else values = [draft]
  return new Set(values).size === values.length &&
    values.every(value => field.options?.some(option => option.value === value)) ? values : null
}

export function choiceDraft(field, draft, value) {
  if (!field.multiple) return value
  const current = choiceValues(field, draft)
  if (!current) throw new Error('Invalid selection draft')
  return renderTerm(list((current.includes(value)
    ? current.filter(item => item !== value) : [...current, value]).map(readTerm)))
}

export function guiContainer(kind) {
  return ['form', 'container', 'panel', 'group', 'row', 'column', 'grid', 'scroll', 'tabs', 'menu', 'dialog'].includes(kind)
}

export function guiDisplay(kind) {
  return ['label', 'status', 'help', 'error', 'separator', 'progress', 'image'].includes(kind)
}
