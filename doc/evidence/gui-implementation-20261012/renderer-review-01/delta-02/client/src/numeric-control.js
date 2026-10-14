import { StackPanel } from '@babylonjs/gui/2D/controls/stackPanel.js'
import { InputText } from '@babylonjs/gui/2D/controls/inputText.js'
import { Slider } from '@babylonjs/gui/2D/controls/sliders/slider.js'
import { TextBlock } from '@babylonjs/gui/2D/controls/textBlock.js'
import { Vector2 } from '@babylonjs/core/Maths/math.vector.js'

// A rotary presentation of Babylon's slider. Pointer ownership, dual-controller
// filtering, release and canvas-blur handling stay in its existing base class.
class RotarySlider extends Slider {
  _onPointerDown(...args) {
    this.previousAngle = undefined
    return super._onPointerDown(...args)
  }
  _updateValueFromPointer(x, y) {
    const local = this.getLocalCoordinates(new Vector2(x, y))
    x = local.x - this.widthInPixels / 2
    y = local.y - this.heightInPixels / 2
    if (Math.hypot(x, y) < 20) return
    let angle = Math.atan2(x, -y)
    if (this.previousAngle !== undefined) {
      while (angle - this.previousAngle > Math.PI) angle -= 2 * Math.PI
      while (angle - this.previousAngle < -Math.PI) angle += 2 * Math.PI
    }
    this.previousAngle = angle
    const sweep = 3 * Math.PI / 4
    this.value = this.minimum + Math.min(1, Math.max(0, (angle + sweep) / (2 * sweep))) * (this.maximum - this.minimum)
  }
  _draw(context) {
    context.save()
    this._applyStates(context)
    const { left, top, width, height } = this._currentMeasure
    const radius = Math.min(width, height) / 2 - 4
    context.translate(left + width / 2, top + height / 2)
    context.fillStyle = this.isEnabled ? this.background : this.disabledColor
    context.strokeStyle = '#BAC9CC'; context.lineWidth = 4
    context.beginPath(); context.arc(0, 0, radius, 0, Math.PI * 2); context.fill(); context.stroke()
    const fraction = this.maximum === this.minimum ? 0.5 : (this.value - this.minimum) / (this.maximum - this.minimum)
    context.rotate((fraction * 1.5 - 0.75) * Math.PI)
    context.fillStyle = this.color
    context.fillRect(-4, -radius + 10, 8, radius - 16)
    context.restore()
  }
}

// Both numeric controls expose the same exact integer grid and direct-entry
// alternative. This adapter owns no draft, validation authority or submission.
export function createNumericControl(field, parent, width, button, keyboard, edit) {
  const { min, max, step } = field.range ?? {}
  if (![min, max, step].every(Number.isSafeInteger) || min > max || step <= 0 ||
      !Number.isSafeInteger(max - min)) throw new Error('Unsupported numeric range')
  const last = min + Math.floor((max - min) / step) * step
  const row = new StackPanel(field.role)
  row.isVertical = false
  row.height = field.kind === 'rotary_knob' ? '156px' : '70px'
  parent.addControl(row)
  let value = min
  let enabled = false
  let editable = false
  let updating = false
  const quantize = candidate => min + Math.round((Math.min(last, Math.max(min, candidate)) - min) / step) * step
  const change = candidate => {
    if (enabled && !updating && Number.isFinite(candidate)) {
      const next = quantize(candidate)
      if (next !== value) edit(String(next))
    }
  }
  const minus = button(`${field.role}-less`, '−', row, () => change(value - step), '64px')
  const rotary = field.kind === 'rotary_knob'
  const slider = rotary ? new RotarySlider(`${field.role}-dial`) : new Slider(`${field.role}-slider`)
  // Babylon snaps its step relative to zero; ontology ranges snap to Min.
  // Keep its pointer continuous and quantize once through our shared grid.
  slider.minimum = min; slider.maximum = last
  slider.width = rotary ? '140px' : `${Math.max(64, width - 410)}px`
  slider.height = rotary ? '140px' : '48px'
  slider.thumbWidth = '48px'; slider.color = '#F9C80E'; slider.background = '#0F1B20'
  slider.disabledColor = '#243B43'
  slider.onValueChangedObservable.add(change)
  // Babylon's generic Control disposal removes hover/down references but not
  // a slider's pointer capture. Reuse its own blur cancellation before retirement.
  const cancel = () => slider._onCanvasBlur()
  slider.onDisposeObservable.add(cancel)
  row.addControl(slider)
  const plus = button(`${field.role}-more`, '+', row, () => change(value + step), '64px')
  const input = new InputText(`${field.role}-number`)
  input.width = '170px'; input.height = '54px'; input.fontSize = 24
  input.color = '#F5F1EB'; input.background = '#0F1B20'; input.disableMobilePrompt = true
  input.focusedBackground = '#0F1B20'; input.disabledColor = '#243B43'
  input.onTextChangedObservable.add(() => {
    // Preserve incomplete or invalid local drafts, so submission cannot quietly
    // send the previous valid number while the human sees something else.
    if (editable && !updating) edit(input.text)
  })
  row.addControl(input)
  keyboard.connect(input)
  const feedback = new TextBlock(`${field.role}-error`)
  feedback.fontSize = 20; feedback.color = '#FFD7A8'; feedback.textWrapping = true
  feedback.height = '48px'
  parent.addControl(feedback)
  return {
    cancel,
    update(next, active) {
      updating = true
      const valid = typeof next === 'string' && /^-?\d+$/.test(next) && Number.isSafeInteger(Number(next)) &&
        Number(next) >= min && Number(next) <= last && (Number(next) - min) % step === 0
      value = valid ? Number(next) : min
      editable = active
      if (enabled && !(active && valid)) cancel()
      enabled = active && valid
      feedback.text = valid ? '' : `Enter ${min} to ${last}, in steps of ${step}.`
      feedback.isVisible = !valid
      minus.isEnabled = enabled && value > min
      plus.isEnabled = enabled && value < last
      input.isEnabled = editable
      input.text = next ?? ''
      slider.isReadOnly = !enabled
      slider.isEnabled = enabled && last > min
      // An invalid draft has no numeric position; do not imply it equals Min.
      slider.isVisible = valid
      slider.value = value
      updating = false
    },
  }
}
