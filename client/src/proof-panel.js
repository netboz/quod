import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder.js'
// CreateForMesh uses Babylon's registered standard-material factory.
import '@babylonjs/core/Materials/standardMaterial.js'
import '@babylonjs/core/Culling/ray.js'
import { AdvancedDynamicTexture } from '@babylonjs/gui/2D/advancedDynamicTexture.js'
import { StackPanel } from '@babylonjs/gui/2D/controls/stackPanel.js'
import { TextBlock } from '@babylonjs/gui/2D/controls/textBlock.js'
import { InputText } from '@babylonjs/gui/2D/controls/inputText.js'
import { Button } from '@babylonjs/gui/2D/controls/button.js'
import { ScrollViewer } from '@babylonjs/gui/2D/controls/scrollViewers/scrollViewer.js'
import { VirtualKeyboard } from '@babylonjs/gui/2D/controls/virtualKeyboard.js'

// A spatial adapter for the existing semantic proof form. It only displays
// state and invokes the same controls as the desktop; it owns no proof/cursor.
export function createProofPanel(scene) {
  const mesh = MeshBuilder.CreatePlane('proof-workspace', { width: 1.6, height: 1.4 }, scene)
  mesh.isVisible = false
  const texture = AdvancedDynamicTexture.CreateForMesh(mesh, 1280, 1120)
  texture.background = '#192B32'
  const form = new StackPanel('proof-form')
  form.width = '1200px'
  texture.addControl(form)
  let model = null
  let synchronizing = false

  function label(name, height, size) {
    const control = new TextBlock(name)
    control.height = `${height}px`
    control.fontSize = size
    control.color = '#F5F1EB'
    control.textWrapping = true
    form.addControl(control)
    return control
  }

  const title = label('proof-title', 56, 32)
  const scope = label('proof-scope', 54, 20)
  const goalLabel = label('proof-goal-label', 40, 24)
  const editor = new InputText('proof-goal')
  editor.height = '68px'
  editor.width = '1180px'
  editor.fontSize = 28
  editor.color = '#F5F1EB'
  editor.background = '#0F1B20'
  editor.disableMobilePrompt = true
  editor.onTextChangedObservable.add(() => {
    if (!synchronizing && model && !model.locked) model.edit(editor.text)
  })
  form.addControl(editor)

  const actions = new StackPanel('proof-actions')
  actions.isVertical = false
  actions.height = '70px'
  form.addControl(actions)
  const buttons = new Map()
  for (const role of ['run', 'next', 'accept', 'stop', 'close']) {
    const button = Button.CreateSimpleButton(`proof-${role}`, '')
    button.width = '236px'
    button.height = '58px'
    button.fontSize = 24
    button.color = '#F5F1EB'
    button.background = role === 'accept' ? '#785A17' : '#304C56'
    button.onPointerClickObservable.add(() => {
      if (button.isEnabled) model?.[role]()
    })
    actions.addControl(button)
    buttons.set(role, button)
  }
  label('proof-write-warning', 56, 21).text = 'Writes stay staged until Accept. Return to lobby keeps your draft and proof.'
  const resultLabel = label('proof-results-label', 40, 24)
  const scroll = new ScrollViewer('proof-results-scroll')
  scroll.height = '300px'
  scroll.barSize = 28
  const results = new TextBlock('proof-results')
  results.color = '#F5F1EB'
  results.fontSize = 24
  results.textWrapping = true
  results.resizeToFit = true
  results.textHorizontalAlignment = 0
  results.paddingLeft = '16px'
  results.paddingRight = '36px'
  scroll.addControl(results)
  form.addControl(scroll)

  const keyboard = new VirtualKeyboard('proof-keyboard')
  keyboard.defaultButtonWidth = '70px'
  keyboard.defaultButtonHeight = '48px'
  keyboard.defaultButtonColor = '#F5F1EB'
  keyboard.defaultButtonBackground = '#304C56'
  keyboard.fontSize = 23
  for (const row of [
    ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '←'],
    ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'],
    ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'],
    ['⇧', 'z', 'x', 'c', 'v', 'b', 'n', 'm', '_', ' '],
    ['(', ')', '[', ']', ',', '.', ':', ';', "'", '"', '\\'],
    ['=', '-', '+', '*', '/', '<', '>', '|', '!', '?', '%'],
  ]) keyboard.addKeysRow(row)
  form.addControl(keyboard)
  keyboard.connect(editor)

  return {
    update(next, visible) {
      model = next
      if (visible && !mesh.isVisible) {
        const camera = scene.activeCamera
        const position = camera.globalPosition
        mesh.position.copyFrom(position.add(camera.getForwardRay().direction.scale(1.6)))
        // Plane front faces -Z; pointing +Z at the viewer mirrors the text.
        mesh.lookAt(position, Math.PI)
      }
      mesh.isVisible = visible
      mesh.isPickable = visible
      if (!visible) texture.focusedControl = null
      synchronizing = true
      editor.text = next.goal
      synchronizing = false
      editor.isEnabled = !next.locked
      keyboard.isEnabled = !next.locked
      title.text = next.view.title
      scope.text = next.scope
      goalLabel.text = next.view.goal
      resultLabel.text = next.view.results
      results.text = next.result
      for (const [role, button] of buttons) {
        button.textBlock.text = role === 'close' ? 'Return to lobby' : next.view[role]
        button.isEnabled = role === 'close' || next.enabled[role]
        button.alpha = button.isEnabled ? 1 : 0.4
      }
    },
    dispose() {
      model = null
      keyboard.disconnect(editor)
      texture.dispose()
      mesh.dispose(false, true)
    },
  }
}
