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
import { Slider } from '@babylonjs/gui/2D/controls/sliders/slider.js'
import { Rectangle } from '@babylonjs/gui/2D/controls/rectangle.js'
import { createNumericControl } from './numeric-control.js'

// A spatial adapter for semantic GUI forms. The controller owns drafts and
// proofs; these controls only display values and invoke its explicit actions.
export function createWorkspacePanel(scene) {
  const mesh = MeshBuilder.CreatePlane('workspace', { width: 1.8, height: 1.7 }, scene)
  mesh.isVisible = false
  const texture = AdvancedDynamicTexture.CreateForMesh(mesh, 1280, 1440)
  // Opacity belongs to the panel's background, never the control hierarchy.
  texture.background = 'rgba(25,43,50,0.78)'
  const form = new StackPanel('workspace-form')
  form.width = '1200px'
  texture.addControl(form)
  let model = null
  let synchronizing = false
  let schema = null
  let lastView = null
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
  const appearance = new StackPanel('workspace-appearance')
  appearance.isVertical = false
  appearance.height = '70px'
  form.addControl(appearance)
  const opacityLabel = new TextBlock('workspace-opacity-label')
  opacityLabel.width = '290px'
  opacityLabel.color = '#F5F1EB'
  opacityLabel.fontSize = 24
  appearance.addControl(opacityLabel)
  const opacity = new Slider('workspace-opacity')
  opacity.minimum = 0.5
  opacity.maximum = 1
  opacity.step = 0.01
  opacity.value = 0.78
  opacity.width = '460px'
  opacity.height = '48px'
  opacity.color = '#F9C80E'
  opacity.background = '#0F1B20'
  opacity.thumbWidth = '48px'
  const showOpacity = () => {
    const percent = Math.round(opacity.value * 100)
    opacityLabel.text = `Panel opacity: ${percent}%`
    texture.background = `rgba(25,43,50,${percent / 100})`
  }
  opacity.onValueChangedObservable.add(showOpacity)
  appearance.addControl(opacity)
  button('workspace-opacity-less', '−', appearance, () => { opacity.value -= 0.05 }, '90px')
  button('workspace-opacity-more', '+', appearance, () => { opacity.value += 0.05 }, '90px')
  button('workspace-opaque', 'Opaque', appearance, () => { opacity.value = 1 }, '200px')
  showOpacity()
  const content = new StackPanel('workspace-fields')
  const viewport = new ScrollViewer('workspace-scroll')
  viewport.height = '650px'
  viewport.barSize = 24
  viewport.addControl(content)
  form.addControl(viewport)
  const actions = new StackPanel('workspace-actions')
  actions.isVertical = true
  actions.height = '70px'
  const actionViewport = new ScrollViewer('workspace-action-scroll')
  actionViewport.height = '70px'
  actionViewport.barSize = 24
  actionViewport.addControl(actions)
  form.addControl(actionViewport)
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
    control.textBlock.textWrapping = true
    control.color = '#F5F1EB'
    control.background = '#304C56'
    control.disabledColor = '#243B43'
    control.disabledColorItem = '#BAC9CC'
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
      actionViewport.height = `${Math.min(140, actions.children.length * 70)}px`
    }
    return button(name, text, row, invoke)
  }

  function rebuild(view) {
    // Blur while the old control and keyboard still own their observers.
    // Babylon's control disposal does not clear the texture's focused control.
    texture.focusedControl = null
    keyboard.disconnect()
    for (const child of [...content.children, ...actions.children]) child.dispose()
    fields = new Map()
    const component = (field, parent, width, inheritedEnabled = true) => {
      const { role, kind } = field
      const active = inheritedEnabled && field.enabled !== false
      if (kind === 'container' || kind === 'form') {
        const group = new StackPanel(role)
        group.width = `${width}px`
        parent.addControl(group)
        if (field.label) {
          const heading = new TextBlock(`${role}-label`, field.label)
          heading.height = '40px'; heading.fontSize = 24; heading.color = '#F5F1EB'
          group.addControl(heading)
        }
        const children = field.children ?? []
        // Wrap composed rows by available readable control width. Adding fields
        // must not shrink hit targets or put controls outside the panel.
        const columns = field.layout === 'row' ? Math.max(1, Math.min(children.length, Math.floor(width / 560))) : 1
        const childWidth = width / columns
        if (columns === 1) {
          for (const child of children) component(child, group, width, active)
          return
        }
        let row
        for (const [index, child] of children.entries()) {
          if (index % columns === 0) {
            row = new StackPanel(`${role}-row-${index}`)
            row.isVertical = false
            row.adaptHeightToChildren = true
            group.addControl(row)
          }
          const cell = new StackPanel(`${child.role}-cell`)
          cell.width = `${childWidth}px`
          row.addControl(cell)
          component(child, cell, childWidth, active)
        }
        return
      }
      if (kind === 'button') {
        fields.set(role, { kind, active, control: action(role, field.label, () => model.invoke(role)) })
        return
      }
      const caption = new TextBlock(`${role}-label`, field.unit ? `${field.label} (${field.unit})` : field.label)
      caption.height = '36px'
      caption.fontSize = 22
      caption.color = '#F5F1EB'
      caption.textWrapping = true
      caption.resizeToFit = true
      parent.addControl(caption)
      if (field.help) {
        const help = new TextBlock(`${role}-help`, field.help)
        help.fontSize = 20; help.color = '#F5F1EB'; help.textWrapping = true; help.resizeToFit = true
        parent.addControl(help)
      }
      if (kind === 'slider' || kind === 'rotary_knob') {
        const numeric = createNumericControl(field, parent, width, button, keyboard,
          value => { if (model && !model.locked) model.edit(role, value) })
        fields.set(role, { kind, active, readonly: field.readonly, numeric })
        return
      }
      if (kind === 'editor' || kind === 'text_box') {
        const control = kind === 'editor' ? new InputTextArea(role) : new InputText(role)
        control.height = kind === 'editor' ? '260px' : '54px'
        control.width = `${width - 60}px`
        control.fontSize = 24
        control.color = '#F5F1EB'
        control.background = '#0F1B20'
        control.focusedBackground = '#0F1B20'
        control.disabledColor = '#243B43'
        control.autoStretchHeight = false
        control.disableMobilePrompt = true
        control.onTextChangedObservable.add(() => {
          if (!synchronizing && control.isEnabled && model && !model.locked) model.edit(role, control.text)
        })
        parent.addControl(control)
        keyboard.connect(control)
        let feedback
        if (kind === 'text_box') {
          feedback = new TextBlock(`${role}-error`)
          feedback.height = '36px'; feedback.fontSize = 20; feedback.color = '#FFD7A8'
          feedback.textWrapping = true
          parent.addControl(feedback)
        }
        fields.set(role, { kind, active, readonly: field.readonly, control, feedback,
          required: field.required, maxBytes: field.maxBytes })
      } else if (kind === 'bindings') {
        const scroll = new ScrollViewer(`${role}-scroll`)
        scroll.height = '180px'
        scroll.barSize = 28
        scroll.background = '#0F1B20'
        const control = new TextBlock(role)
        control.color = '#F5F1EB'
        control.fontSize = 22
        control.textWrapping = true
        control.resizeToFit = true
        control.textHorizontalAlignment = 0
        scroll.addControl(control)
        parent.addControl(scroll)
        fields.set(role, { kind, control })
      } else if (kind === 'selection' || kind === 'catalogue_selection') {
        const row = new StackPanel(role)
        row.height = '62px'
        row.isVertical = false
        parent.addControl(row)
        const choose = direction => {
          if (model.locked || !active || field.readonly) return
          const options = model.choices?.[role] ?? field.options ?? []
          if (!options.length) return
          const at = options.findIndex(option => option.value === model.values[role])
          model.edit(role, options[at < 0 ? 0 : (at + direction + options.length) % options.length].value)
        }
        const previous = button(`${role}-previous`, '‹', row, () => choose(-1), '100px')
        const control = new TextBlock(`${role}-value`)
        control.color = '#F5F1EB'
        control.fontSize = 24
        control.textWrapping = true
        const surface = new Rectangle(`${role}-surface`)
        surface.width = `${Math.max(0, width - 260)}px`
        surface.background = '#0F1B20'
        surface.thickness = 0
        surface.addControl(control)
        row.addControl(surface)
        const next = button(`${role}-next`, '›', row, () => choose(1), '100px')
        fields.set(role, { kind, active, readonly: field.readonly, options: field.options, control, previous, next })
      } else {
        throw new Error(`Unsupported spatial GUI component: ${kind}`)
      }
    }
    component({ kind: 'container', role: 'workspace-content-root', label: '',
      layout: view.layout, children: view.fields }, content, 1200, view.enabled !== false)
    action('close-workspace', 'Return to lobby', () => model.close())
  }

  return {
    update(next, visible) {
      model = next
      if (lastView !== next.view) {
        const signature = JSON.stringify(next.view)
        if (schema !== signature) { rebuild(next.view); schema = signature }
        lastView = next.view
      }
      if (visible && !mesh.isVisible) {
        const camera = scene.activeCamera
        const position = camera.globalPosition
        mesh.position.copyFrom(position.add(camera.getForwardRay().direction.scale(1.6)))
        // Plane front faces -Z; pointing +Z at the viewer mirrors the text.
        mesh.lookAt(position, Math.PI)
      }
      mesh.isVisible = visible
      mesh.isPickable = visible
      if (!visible) {
        texture.focusedControl = null
        opacity._onCanvasBlur()
        for (const field of fields.values()) field.numeric?.cancel()
      }
      synchronizing = true
      title.text = next.view.title
      scope.text = next.scope
      keyboard.isEnabled = !next.locked
      for (const [role, field] of fields) {
        if (field.kind === 'button') {
          field.control.isEnabled = field.active && !!next.enabled[role]
          field.control.alpha = 1
        } else if (field.numeric) {
          field.numeric.update(next.values[role], !next.locked && field.active && !field.readonly)
        } else {
          const value = next.values[role] ?? ''
          field.control.text = field.kind === 'selection' || field.kind === 'catalogue_selection'
            ? ((next.choices?.[role] ?? field.options)?.find(option => option.value === value)?.label ?? value) : value
          if (field.kind === 'editor' || field.kind === 'text_box') field.control.isEnabled = !next.locked && field.active && !field.readonly
          if (field.feedback) {
            const length = new TextEncoder().encode(value).length
            field.feedback.text = field.required && !length ? 'This field is required.'
              : field.maxBytes !== undefined && length > field.maxBytes ? `${length} bytes; maximum ${field.maxBytes}.` : ''
            field.feedback.isVisible = !!field.feedback.text
          }
          if (field.kind === 'selection' || field.kind === 'catalogue_selection') {
            field.previous.isEnabled = field.next.isEnabled = !next.locked && field.active && !field.readonly
          }
        }
      }
      if (texture.focusedControl && !texture.focusedControl.isEnabled) texture.focusedControl = null
      synchronizing = false
    },
    dispose() {
      model = null
      texture.focusedControl = null
      opacity._onCanvasBlur()
      keyboard.disconnect()
      texture.dispose()
      mesh.dispose(false, true)
    },
  }
}
