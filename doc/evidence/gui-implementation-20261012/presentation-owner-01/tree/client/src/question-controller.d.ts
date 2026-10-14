import type { SignedIdentity, AgentReference } from './signed-client.js'
import type { GuiQuestionReference, GuiQuestionForm } from './world.js'
export type QuestionState = {
  form: GuiQuestionForm | null
  draftView: GuiQuestionForm['view'] | null
  draft: Record<string, string>
  locked: boolean
  busy: boolean
  pending: number
  status: string
  canCancel: boolean
}
export function questionKey(reference: GuiQuestionReference): string
export type QuestionController = {
  readonly started: boolean
  readonly current: QuestionState
  subscribe(listener: (state: QuestionState) => void): () => void
  ready: Promise<void>
  refresh(): void
  resolve(): Promise<void>
  check(): Promise<void>
  submit(): Promise<void>
  cancel(): Promise<void>
  resetDraft(): void
  edit(role: string, value: string): void
  close(): void
}

export function questionController(identity: SignedIdentity, agent: AgentReference,
  reference: GuiQuestionReference, options?: { deferOpen?: boolean }): QuestionController
