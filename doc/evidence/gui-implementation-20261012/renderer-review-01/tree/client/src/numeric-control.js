import { StackPanel } from '@babylonjs/gui/2D/controls/stackPanel.js'
import { InputText } from '@babylonjs/gui/2D/controls/inputText.js'
import { Slider } from '@babylonjs/gui/2D/controls/sliders/slider.js'
import { Ellipse } from '@babylonjs/gui/2D/controls/ellipse.js'
import { Rectangle } from '@babylonjs/gui/2D/controls/rectangle.js'
import { Vector2 } from '@babylonjs/core/Maths/math.vector.js'

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
  let updating = false
  const quantize = candidate => min + Math.round((Math.min(last, Math.max(min, candidate)) - min) / step) * step
  const change = candidate => {
    if (enabled && !updating && Number.isFinite(candidate)) edit(String(quantize(candidate)))
  }
  const minus = button(`${field.role}-less`, '−', row, () => change(value - step), '64px')
  let dial, indicator, slider, dragging = false, previousAngle
  if (field.kind === 'rotary_knob') {
    dial = new Ellipse(`${field.role}-dial`)
    dial.width = dial.height = '140px'
    dial.color = '#BAC9CC'
    dial.background = '#0F1B20'
    dial.thickness = 4
    row.addControl(dial)
    indicator = new Rectangle(`${field.role}-indicator`)
    indicator.width = '8px'; indicator.height = '52px'
    indicator.top = '-26px'
    indicator.transformCenterY = 1
    indicator.background = '#F9C80E'
    indicator.thickness = 0
    indicator.isHitTestVisible = false
    dial.addControl(indicator)
    const point = pointer => {
      if (!dragging || !enabled) return
      const local = dial.getLocalCoordinates(new Vector2(pointer.x, pointer.y))
      const x = local.x - 70, y = local.y - 70
      // The centre has no useful angular selection; it must not jump a value.
      if (Math.hypot(x, y) < 20) return
      let angle = Math.atan2(x, -y)
      if (previousAngle !== undefined) {
        while (angle - previousAngle > Math.PI) angle -= 2 * Math.PI
        while (angle - previousAngle < -Math.PI) angle += 2 * Math.PI
      }
      previousAngle = angle
      const sweep = 3 * Math.PI / 4
      change(min + Math.min(1, Math.max(0, (angle + sweep) / (2 * sweep))) * (last - min))
    }
    dial.onPointerDownObservable.add(pointer => { dragging = enabled; previousAngle = undefined; point(pointer) })
    dial.onPointerMoveObservable.add(point)
    dial.onPointerUpObservable.add(() => { dragging = false })
  } else {
    slider = new Slider(`${field.role}-slider`)
    // Babylon snaps its step relative to zero; ontology ranges snap to Min.
    // Keep its pointer continuous and quantize once through our shared grid.
    slider.minimum = min; slider.maximum = last
    slider.width = `${Math.max(64, width - 410)}px`; slider.height = '48px'
    slider.thumbWidth = '48px'; slider.color = '#F9C80E'; slider.background = '#0F1B20'
    slider.onValueChangedObservable.add(change)
    row.addControl(slider)
  }
  const plus = button(`${field.role}-more`, '+', row, () => change(value + step), '64px')
  const input = new InputText(`${field.role}-number`)
  input.width = '170px'; input.height = '54px'; input.fontSize = 24
  input.color = '#F5F1EB'; input.background = '#0F1B20'; input.disableMobilePrompt = true
  input.onTextChangedObservable.add(() => {
    if (!enabled || updating || !/^-?\d+$/.test(input.text)) return
    const candidate = Number(input.text)
    if (Number.isSafeInteger(candidate) && candidate >= min && candidate <= last &&
        (candidate - min) % step === 0) edit(input.text)
  })
  input.onBlurObservable.add(() => {
    updating = true; input.text = String(value); updating = false
  })
  row.addControl(input)
  keyboard.connect(input)
  return {
    update(next, active) {
      updating = true
      value = Number(next)
      enabled = active
      if (!enabled) dragging = false
      minus.isEnabled = enabled && value > min
      plus.isEnabled = enabled && value < last
      input.isEnabled = enabled
      input.text = String(next)
      if (slider) { slider.isEnabled = enabled && last > min; slider.value = value }
      if (dial) {
        dial.isEnabled = enabled && last > min
        indicator.rotation = (last === min ? 0 : (value - min) / (last - min) * 1.5 - 0.75) * Math.PI
      }
      updating = false
    },
  }
}
