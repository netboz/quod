import { useEffect, useState } from 'react'
import { GuiForm } from './GuiForm'
import type { QuestionState, QuestionController } from '../../client/src/question-controller.js'
import type { GuiQuestionReference } from '../../client/src/world.js'
import type { WorkspacePanelModel, WorldScene } from '../../client/src/world-scene.js'

export function GuiQuestion({ reference, controller, scene, visible, onClose }: {
  reference: GuiQuestionReference; controller: QuestionController
  scene: WorldScene | null; visible: boolean; onClose(): void
}) {
  const [state, setState] = useState<QuestionState>(controller.current)
  useEffect(() => controller.subscribe(setState), [controller])
  useEffect(() => () => scene?.setWorkspace(null), [scene])
  const form = state?.form
  const draftView = state?.draftView
  // These local toolbar roles are not canonical Prolog component terms and
  // cannot be submitted as ontology controls.
  const actions: Record<string, () => void> = {
    '@question/resolve': () => { void controller.resolve() },
    '@question/check': () => { void controller.check() },
    '@question/cancel': () => { void controller.cancel() },
    '@question/refresh': () => controller.refresh(),
    '@question/defaults': () => controller.resetDraft(),
  }
  const model: WorkspacePanelModel = {
    view: { title: draftView?.title ?? 'Question', fields: [
      ...(form && draftView && form.interaction !== 'submitted' ? [{ kind: 'container', role: '@question/form',
        label: form.interaction === 'stale' ? 'Draft (form changed)' : '',
        enabled: draftView.enabled, layout: draftView.layout, children: draftView.fields }] : []),
      { kind: 'text_box', role: '@question/status', label: 'Status', readonly: true },
      ...[['resolve', 'Check saved operation'], ['check', 'Check answer status'],
        ['cancel', 'Cancel question'], ['refresh', 'Reload question'], ['defaults', 'Use current defaults']].map(([role, label]) =>
        ({ kind: 'button', role: `@question/${role}`, label })),
    ] },
    scope: reference.namespace,
    values: { ...state?.draft, '@question/status': state?.status ?? 'Loading question…' },
    locked: state?.locked ?? true,
    enabled: { ...(form ? { [form.submit]: !state?.locked } : {}),
      '@question/resolve': !!state?.pending && !state.busy,
      '@question/check': !!state && !state.busy && !state.pending,
      '@question/cancel': state?.canCancel ?? false,
      '@question/defaults': !!state && !state.locked,
      '@question/refresh': !state?.busy },
    edit: (role, value) => controller.edit(role, value),
    invoke(role) {
      if (!model.enabled[role]) return
      if (form && role === form.submit) void controller.submit()
      else actions[role]?.()
    },
    close: onClose,
  }
  useEffect(() => { scene?.setWorkspace(visible ? model : null) })
  return <GuiForm model={model} />
}

export function GuiQuestionList({ references, status, scene, visible, select, reload, onClose }: {
  references: GuiQuestionReference[]; status: string | null; scene: WorldScene | null; visible: boolean
  select(reference: GuiQuestionReference): void; reload(): void; onClose(): void
}) {
  const model: WorkspacePanelModel = {
    view: { title: 'Pending questions', fields: [
      { kind: 'text_box', role: 'status', label: 'Status', readonly: true },
      ...references.map((ref, index) => ({ kind: 'button', role: String(index),
        label: `Question ${index + 1} · ${ref.namespace}` })),
      { kind: 'button', role: 'reload', label: 'Reload questions' },
    ] },
    scope: 'Questions addressed to you', locked: false,
    values: { status: status ?? (references.length ? 'Choose a question when you are ready.' : 'No pending questions.') },
    enabled: Object.fromEntries([...references.map((_, index) => [String(index), true]), ['reload', true]]),
    edit() {},
    invoke(role) {
      if (role === 'reload') reload()
      else if (references[Number(role)]) select(references[Number(role)])
    },
    close: onClose,
  }
  useEffect(() => () => scene?.setWorkspace(null), [scene])
  useEffect(() => { scene?.setWorkspace(visible ? model : null) })
  return <GuiForm model={model} />
}
