import test from 'node:test'
import assert from 'node:assert/strict'
import { configureDesktopCamera, createMovementSpeed, createPointerLock } from '../src/navigation.js'

test('desktop camera uses familiar movement keys and measured controls', () => {
  const camera = {}
  configureDesktopCamera(camera)
  assert.deepEqual(camera.keysUp, [87, 38])
  assert.deepEqual(camera.keysDown, [83, 40])
  assert.deepEqual(camera.keysLeft, [65, 37])
  assert.deepEqual(camera.keysRight, [68, 39])
  assert.equal(camera.speed, 2)
  assert.equal(camera.angularSensibility, 2600)
})

test('Shift accelerates movement and releasing focus restores walking speed', () => {
  const owner = new EventTarget()
  owner.defaultView = new EventTarget()
  const canvas = { ownerDocument: owner }
  const camera = {}
  const speed = createMovementSpeed(canvas, camera)
  const shift = type => {
    const event = new Event(type)
    Object.defineProperty(event, 'key', { value: 'Shift' })
    owner.dispatchEvent(event)
  }

  assert.equal(camera.speed, 2)
  shift('keydown')
  assert.equal(camera.speed, 5)
  shift('keyup')
  assert.equal(camera.speed, 2)
  shift('keydown')
  owner.defaultView.dispatchEvent(new Event('blur'))
  assert.equal(camera.speed, 2)
  speed.dispose()
  shift('keydown')
  assert.equal(camera.speed, 2)
})

test('pointer capture follows the canvas lifecycle and releases cleanly', async () => {
  const owner = new EventTarget()
  owner.pointerLockElement = null
  owner.exitPointerLock = () => {
    owner.pointerLockElement = null
    owner.dispatchEvent(new Event('pointerlockchange'))
  }
  const canvas = new EventTarget()
  canvas.ownerDocument = owner
  canvas.focused = false
  canvas.focus = () => { canvas.focused = true }
  canvas.requestPointerLock = () => {
    owner.pointerLockElement = canvas
    owner.dispatchEvent(new Event('pointerlockchange'))
    return Promise.resolve()
  }
  const changes = []
  const lock = createPointerLock(canvas, { onChanged: active => changes.push(active) })
  canvas.dispatchEvent(new Event('click'))
  await Promise.resolve()
  assert.equal(lock.active(), true)
  assert.equal(canvas.focused, true)
  lock.release()
  assert.equal(lock.active(), false)
  lock.dispose()
  canvas.dispatchEvent(new Event('click'))
  assert.equal(lock.active(), false)
  assert.deepEqual(changes, [false, true, false])
})
