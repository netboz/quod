import type { SignedIdentity, AgentReference } from './signed-client.js'
import type { GuiQuestionReference, GuiQuestionForm } from './world.js'
export type ViewCallbacks<T> = {
  projection(value: T): void
  unavailable(reason: string): void
  refreshing?(reason: string): void | boolean
  discard?(): void
}
export function connectGuiHud(identity: SignedIdentity, agent: AgentReference,
  callbacks: ViewCallbacks<GuiQuestionReference[]>): { close(): void }
export function connectGuiQuestion(identity: SignedIdentity, agent: AgentReference,
  reference: GuiQuestionReference, callbacks: ViewCallbacks<GuiQuestionForm>): { close(): void }
