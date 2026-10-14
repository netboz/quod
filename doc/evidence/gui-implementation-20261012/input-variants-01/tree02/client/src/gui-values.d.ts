export type NumericRange = { min: number; max: number; step: number; last: number }
export function numericControlRange(range?: { min: number; max: number; step: number }): NumericRange
export function numericDraft(range: NumericRange, text: string): number | null
export function textFeedback(field: { required?: boolean; maxBytes?: number }, value: string): string
export function guiValueKind(kind: string): 'text' | 'number' | 'boolean' | 'choice' | null
export type ChoiceField = { multiple?: boolean; options?: { value: string; label: string }[] }
export function choiceValues(field: ChoiceField, draft: string): string[] | null
export function choiceDraft(field: ChoiceField, draft: string, value: string): string
