import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder.js'
// CreateForMesh uses Babylon's registered standard-material factory.
import '@babylonjs/core/Materials/standardMaterial.js'
import '@babylonjs/core/Culling/ray.js'
import { AdvancedDynamicTexture } from '@babylonjs/gui/2D/advancedDynamicTexture.js'
import { StackPanel } from '@babylonjs/gui/2D/controls/stackPanel.js'
import { TextBlock } from '@babylonjs/gui/2D/controls/textBlock.js'
import { InputText } from '@babylonjs/gui/2D/controls/inputText.js'
import { InputTextArea } from '@babylonjs/gui/2D/controls/inputTextArea.js'
import { Button } from '@babylonjs/gui/2D/controls/button.js'
import { ScrollViewer } from '@babylonjs/gui/2D/controls/scrollViewers/scrollViewer.js'
import { VirtualKeyboard } from '@babylonjs/gui/2D/controls/virtualKeyboard.js'

// A spatial adapter for semantic GUI forms. The controller owns drafts and
// proofs; these controls only display values and invoke its explicit actions.
export function createWorkspacePanel(scene) {
  const mesh = MeshBuilder.CreatePlane('workspace', { width: 1.8, height: 1.7 }, scene)
  mesh.isVisible = false
  const texture = AdvancedDynamicTexture.CreateForMesh(mesh, 1280, 1440)
  texture.background = '#192B32'
  const form = new StackPanel('workspace-form')
  form.width = '1200px'
  texture.addControl(form)
  let model = null
  let synchronizing = false
  let schema = null
  let fields = new Map()

  function label(name, height, size) {
    const control = new TextBlock(name)
    control.height = `${height}px`
    control.fontSize = size
    control.color = '#F5F1EB'
    control.textWrapping = true
    form.addControl(control)
    return control
  }

  const title = label('workspace-title', 56, 32)
  const scope = label('workspace-scope', 54, 20)
  const content = new StackPanel('workspace-fields')
  const viewport = new ScrollViewer('workspace-scroll')
  viewport.height = '650px'
  viewport.barSize = 24
  viewport.addControl(content)
  form.addControl(viewport)
  const actions = new StackPanel('workspace-actions')
  actions.isVertical = true
  actions.height = '70px'
  form.addControl(actions)
  const keyboard = new VirtualKeyboard('workspace-keyboard')
  keyboard.defaultButtonWidth = '70px'
  keyboard.defaultButtonHeight = '48px'
  keyboard.defaultButtonColor = '#F5F1EB'
  keyboard.defaultButtonBackground = '#304C56'
  keyboard.fontSize = 23
  for (const row of [
    ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '←'],
    ['a', 'z', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'],
    ['q', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', 'm'],
    ['⇧', 'w', 'x', 'c', 'v', 'b', 'n', '_', ' ', '↵'],
    ['(', ')', '[', ']', ',', '.', ':', ';', "'", '"', '\\'],
    ['=', '-', '+', '*', '/', '<', '>', '|', '!', '?', '%'],
  ]) keyboard.addKeysRow(row)
  form.addControl(keyboard)

  function button(name, text, parent, invoke, width = '165px') {
    const control = Button.CreateSimpleButton(name, text)
    control.width = width
    control.height = '58px'
    control.fontSize = 24
    control.color = '#F5F1EB'
    control.background = '#304C56'
    control.onPointerClickObservable.add(() => { if (control.isEnabled) invoke() })
    parent.addControl(control)
    return control
  }

  function action(name, text, invoke) {
    // Wrap by available panel width, not by the number of domain actions.
    const columns = Math.floor(1200 / 165)
    let row = actions.children.at(-1)
    if (!row || row.children.length >= columns) {
      row = new StackPanel(`workspace-action-row-${actions.children.length}`)
      row.isVertical = false
      row.height = '70px'
      actions.addControl(row)
      actions.height = `${actions.children.length * 70}px`
    }
    return button(name, text, row, invoke)
  }

  function rebuild(view) {
    keyboard.disconnect()
    for (const child of [...content.children, ...actions.children]) child.dispose()
    fields = new Map()
    for (const field of view.fields) {
      const { role, kind } = field
      if (kind === 'button') {
        fields.set(role, { kind, control: action(role, field.label, () => model.invoke(role)) })
        continue
      }
      const caption = new TextBlock(`${role}-label`, field.label)
      caption.height = '36px'
      caption.fontSize = 22
      caption.color = '#F5F1EB'
      content.addControl(caption)
      if (kind === 'editor' || kind === 'input') {
        const control = kind === 'editor' ? new InputTextArea(role) : new InputText(role)
        control.height = kind === 'editor' ? '260px' : '54px'
        control.width = '1140px'
        control.fontSize = 24
        control.color = '#F5F1EB'
        control.background = '#0F1B20'
        control.autoStretchHeight = false
        control.disableMobilePrompt = true
        control.onTextChangedObservable.add(() => {
          if (!synchronizing && model && !model.locked) model.edit(role, control.text)
        })
        content.addControl(control)
        keyboard.connect(control)
        fields.set(role, { kind, control })
      } else if (kind === 'bindings') {
        const scroll = new ScrollViewer(`${role}-scroll`)
        scroll.height = '180px'
        scroll.barSize = 28
        const control = new TextBlock(role)
        control.color = '#F5F1EB'
        control.fontSize = 22
        control.textWrapping = true
        control.resizeToFit = true
        control.textHorizontalAlignment = 0
        scroll.addControl(control)
        content.addControl(scroll)
        fields.set(role, { kind, control })
      } else if (kind === 'choice') {
        const row = new StackPanel(role)
        row.height = '62px'
        row.isVertical = false
        content.addControl(row)
        const choose = direction => {
          if (model.locked) return
          const options = model.choices?.[role] ?? []
          if (!options.length) return
          const at = options.findIndex(option => option.value === model.values[role])
          model.edit(role, options[(at + direction + options.length) % options.length].value)
        }
        const previous = button(`${role}-previous`, '‹', row, () => choose(-1), '100px')
        const control = new TextBlock(`${role}-value`)
        control.width = '940px'
        control.color = '#F5F1EB'
        control.fontSize = 24
        row.addControl(control)
        const next = button(`${role}-next`, '›', row, () => choose(1), '100px')
        fields.set(role, { kind, control, previous, next })
      } else {
        throw new Error(`Unsupported spatial GUI component: ${kind}`)
      }
    }
    action('close-workspace', 'Return to lobby', () => model.close())
  }

  return {
    update(next, visible) {
      model = next
      const signature = JSON.stringify(next.view)
      if (schema !== signature) { rebuild(next.view); schema = signature }
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
      title.text = next.view.title
      scope.text = next.scope
      keyboard.isEnabled = !next.locked
      for (const [role, field] of fields) {
        if (field.kind === 'button') {
          field.control.isEnabled = !!next.enabled[role]
          field.control.alpha = field.control.isEnabled ? 1 : 0.4
        } else {
          const value = next.values[role] ?? ''
          field.control.text = field.kind === 'choice'
            ? (next.choices?.[role]?.find(option => option.value === value)?.label ?? value) : value
          if (field.kind === 'editor' || field.kind === 'input') field.control.isEnabled = !next.locked
          if (field.kind === 'choice') {
            field.previous.isEnabled = field.next.isEnabled = !next.locked
          }
        }
      }
      synchronizing = false
    },
    dispose() {
      model = null
      keyboard.disconnect()
      texture.dispose()
      mesh.dispose(false, true)
    },
  }
}
