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
