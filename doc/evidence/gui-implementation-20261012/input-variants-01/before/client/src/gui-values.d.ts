export type NumericRange = { min: number; max: number; step: number; last: number }
export function numericControlRange(range?: { min: number; max: number; step: number }): NumericRange
export function numericDraft(range: NumericRange, text: string): number | null
export function textFeedback(field: { required?: boolean; maxBytes?: number }, value: string): string
