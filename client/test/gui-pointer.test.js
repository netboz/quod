import { test } from 'node:test'
import assert from 'node:assert/strict'
import { NullEngine } from '@babylonjs/core/Engines/nullEngine.js'
import { Scene } from '@babylonjs/core/scene.js'
import { AdvancedDynamicTexture } from '@babylonjs/gui/2D/advancedDynamicTexture.js'
import { Button } from '@babylonjs/gui/2D/controls/button.js'
import { Slider } from '@babylonjs/gui/2D/controls/sliders/slider.js'
import { Vector2 } from '@babylonjs/core/Maths/math.vector.js'
import { cancelGuiPointer } from '../src/gui-pointer.js'

test('actual Babylon GUI cancellation releases button and slider capture without clicking or losing the draft', () => {
  const engine = new NullEngine()
  // Rendering is not exercised; the real ADT, controls and pointer state are.
  engine.createCanvas = (width, height) => ({ width, height, getContext: () => ({}) })
  const scene = new Scene(engine), texture = new AdvancedDynamicTexture('cancel', 64, 64, scene)
  try {
    const button = new Button('submit'), slider = new Slider('value')
    texture.addControl(button); texture.addControl(slider)
    let clicks = 0, ups = 0
    button.onPointerClickObservable.add(() => clicks++)
    button.onPointerUpObservable.add(() => ups++)
    const pi = { event: { pointerId: -1 } }, point = Vector2.Zero()
    button._onPointerDown(button, point, -1, 0, pi)
    texture._lastControlDown[-1] = button; texture._lastControlOver[-1] = button
    cancelGuiPointer(texture, -1)
    assert.equal(clicks, 0); assert.equal(ups, 1)
    assert.equal(button._downCount, 0)
    assert.equal(texture._capturedPointerIds.has(-1), false)
    // A later real gesture still clicks exactly once.
    button._onPointerDown(button, point, -1, 0, pi)
    button._onPointerUp(button, point, -1, 0, true, pi)
    assert.equal(clicks, 1)
    slider._onPointerDown(slider, point, -2, 0, { event: { pointerId: -2 } })
    slider.value = 37
    texture._lastControlDown[-2] = slider
    cancelGuiPointer(texture, -2)
    assert.equal(slider.value, 37)
    assert.equal(texture._capturingControl[-2], undefined)
    assert.equal(slider._pointerIsDown, false)
  } finally { texture.dispose(); scene.dispose(); engine.dispose() }
})
