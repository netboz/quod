import type { Subject } from './world.js'
export type WorldScene = { paint(marks: unknown[]): void; immersive(): Promise<void>; dispose(): void }
export function createWorld(canvas: HTMLCanvasElement, onPick: (subject: Subject) => void): WorldScene
