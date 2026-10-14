import type { SignedIdentity, AgentReference } from './signed-client.js'
import type { GuiQuestionReference, GuiQuestionForm } from './world.js'
export type QuestionState = {
  form: GuiQuestionForm | null
  draft: Record<string, string>
  locked: boolean
  busy: boolean
  pending: number
  status: string
  canCancel: boolean
}
export function questionKey(reference: GuiQuestionReference): string
export function questionController(identity: SignedIdentity, agent: AgentReference,
  reference: GuiQuestionReference, changed: (state: QuestionState) => void): {
  ready: Promise<void>
  refresh(): void
  resolve(): Promise<void>
  check(): Promise<void>
  submit(): Promise<void>
  cancel(): Promise<void>
  edit(role: string, value: string): void
  close(): void
}
