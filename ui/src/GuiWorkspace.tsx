import { useEffect, useState } from 'react'
import { GuiForm } from './GuiForm'
import type { WorkspacePanelModel } from '../../client/src/world-scene.js'
export type GuiController = { readonly current: WorkspacePanelModel; subscribe(listener: (model: WorkspacePanelModel) => void): () => void }
import type { WorldScene } from '../../client/src/world-scene.js'

export function GuiWorkspace({ controller, scene, visible }: {
  controller: GuiController; scene: WorldScene | null; visible: boolean
}) {
  const [model, setModel] = useState(controller.current)
  useEffect(() => controller.subscribe(setModel), [controller])
  useEffect(() => () => scene?.setWorkspace(null), [scene])
  useEffect(() => { scene?.setWorkspace(visible ? model : null) }, [scene, visible, model])
  return <GuiForm model={model} />
}
