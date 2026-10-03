import type { PrologTerm } from './prolog-term.js'
/** Read one canonical result term; variable names share only within this call. */
export function readTerm(text: string): PrologTerm
/** Read a ground projection list, rejecting partial tails at every depth. */
export function readList(text: string): PrologTerm[]
