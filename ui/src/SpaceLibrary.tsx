import { useEffect, useState } from 'react'
import { GuiForm } from './GuiForm'
import type { SpaceLibraryController } from '../../client/src/space-library.js'
import type { WorldScene } from '../../client/src/world-scene.js'

export function SpaceLibrary({ controller, scene, visible }: {
  controller: SpaceLibraryController; scene: WorldScene | null; visible: boolean
}) {
  const [model, setModel] = useState(controller.current)
  useEffect(() => controller.subscribe(setModel), [controller])
  useEffect(() => {
    scene?.setWorkspace(visible ? model : null)
    return () => scene?.setWorkspace(null)
  }, [scene, visible, model])
  return <GuiForm model={model} />
}
