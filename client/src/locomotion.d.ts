import type { PrologTerm } from './prolog-term.js'
export type PhysicsControl = {
  term: PrologTerm
  agent: PrologTerm
  revision: string
  epoch: string
  body: string
  bodyRevision: string
  grounded: boolean
  speed: number
  turn: number
  lease: number
  teleport: { reach: number; drop: number; up: number } | null
  snap: number | null
  jump: number | null
  reposition: boolean
  viewpoint: { name: PrologTerm; position: number[]; rotation: number[] }
}
export function readControl(text: string): PhysicsControl | null
export function driveInput(velocity: number[], angular?: number[]): PrologTerm
export function snapInput(angle: number): PrologTerm
export function jumpInput(speed: number): PrologTerm
export function teleportInput(position: number[], origin?: bigint[]): PrologTerm
export function pushInput(body: string, revision: string, impulse: number[]): PrologTerm
