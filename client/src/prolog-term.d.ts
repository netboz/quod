export type PrologTerm =
  | { type: 'atom'; value: string }
  | { type: 'string'; value: string }
  | { type: 'number'; value: number | bigint }
  | { type: 'variable'; value: string }
  | { type: 'compound'; functor: string; args: PrologTerm[] }
  | { type: 'list'; items: PrologTerm[]; tail: PrologTerm | null }

export function atom(value: string): PrologTerm
export function string(value: string): PrologTerm
export function number(value: number | bigint): PrologTerm
export function variable(value: string): PrologTerm
export function compound(functor: string, args: PrologTerm[]): PrologTerm
export function list(items: PrologTerm[], tail?: PrologTerm | null): PrologTerm
export function renderTerm(value: PrologTerm): string
export function goalText(value: PrologTerm): string
