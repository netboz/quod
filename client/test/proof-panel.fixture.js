import { Engine } from '@babylonjs/core/Engines/engine.js'
import { Scene } from '@babylonjs/core/scene.js'
import { ArcRotateCamera } from '@babylonjs/core/Cameras/arcRotateCamera.js'
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js'
import { createProofPanel } from '../src/proof-panel.js'
import { createWorld } from '../src/world-scene.js'
import { EngineStore } from '@babylonjs/core/Engines/engineStore.js'
import { Observable } from '@babylonjs/core/Misc/observable.js'
import { WebXRState } from '@babylonjs/core/XR/webXRTypes.js'

export async function exerciseProofPanel() {
    const engine = new Engine(document.querySelector('canvas'), true, { preserveDrawingBuffer: true })
    const scene = new Scene(engine)
    new ArcRotateCamera('viewer', -Math.PI / 2, Math.PI / 2, 3, Vector3.Zero(), scene)
    const initialMeshes = scene.meshes.length
    const initialObservers = scene.onPointerObservable.observers.length
    const panel = createProofPanel(scene)
    const calls = []
    const model = {
      view: { title: 'Prolog console', goal: 'Prolog goal', results: 'Bindings',
        run: 'Run', next: 'Next solution', accept: 'Accept solution', stop: 'Stop' },
      scope: 'human:test', goal: '', result: '', locked: false,
      enabled: { run: true, next: false, accept: false, stop: false },
      edit(value) { model.goal = value; panel.update(model, true) },
      ...Object.fromEntries(['run', 'next', 'accept', 'stop', 'close'].map(role =>
        [role, () => calls.push(role)])),
    }
    scene.activeCamera.getViewMatrix(true)
    panel.update(model, true)
    const mesh = scene.getMeshByName('proof-workspace')
    mesh.computeWorldMatrix(true)
    const frontFacing = Vector3.Dot(mesh.getDirection(new Vector3(0, 0, -1)),
      scene.activeCamera.globalPosition.subtract(mesh.position)) > 0
    const texture = mesh.material.emissiveTexture
    const editor = texture.getControlByName('proof-goal')
    const keyboard = texture.getControlByName('proof-keyboard')
    const click = role => texture.getControlByName(`proof-${role}`).onPointerClickObservable.notifyObservers({})
    engine.runRenderLoop(() => scene.render())
    const rendered = () => new Promise(resolve => scene.onAfterRenderObservable.addOnce(resolve))
    await scene.whenReadyAsync()
    await rendered()
    texture.focusedControl = editor
    for (const key of ['a', '(', '⇧', 'x', ')', '.']) keyboard.onKeyPressObservable.notifyObservers(key)
    const typed = model.goal
    click('run'); click('accept')
    model.locked = true
    model.enabled = { run: false, next: true, accept: true, stop: true }
    model.result = Array.from({ length: 60 }, (_, i) => `Binding${i} = value(${i})`).join('\n')
    panel.update(model, true)
    click('run'); click('next'); click('accept'); click('stop'); click('close')
    await rendered()
    const scroll = texture.getControlByName('proof-results-scroll')
    const scrollable = scroll.verticalBar.isVisible
    const resultText = texture.getControlByName('proof-results').text
    const locked = !editor.isEnabled && !keyboard.isEnabled
    const sameMesh = mesh === scene.getMeshByName('proof-workspace')
    panel.update(model, false)
    const hidden = !mesh.isVisible && !mesh.isPickable && texture.focusedControl === null
    panel.update(model, true)
    await rendered()
    const screenshot = engine.getRenderingCanvas().toDataURL('image/png')
    panel.dispose()
    await rendered()
    const retired = scene.meshes.length === initialMeshes &&
      scene.onPointerObservable.observers.length === initialObservers
    engine.stopRenderLoop()
    scene.dispose(); engine.dispose()
    // Feed controller and XR lifecycle notices into the real world adapter.
    // This tests wiring; it does not claim physical-headset acceptance.
    const modes = []
    const world = createWorld(document.querySelector('canvas'), () => {}, value => modes.push(value))
    const room = EngineStore.LastCreatedScene
    room.activeCamera.getViewMatrix(true)
    const component = { pressed: false, onAxisValueChangedObservable: new Observable(),
      onButtonStateChangedObservable: new Observable() }
    const changes = new Observable()
    let exits = 0
    room.createDefaultXRExperienceAsync = async () => ({
      input: { controllers: [{ motionController: { getComponentOfType: () => component } }],
        onControllerAddedObservable: new Observable() },
      baseExperience: { onStateChangedObservable: changes,
        enterXRAsync: async () => changes.notifyObservers(WebXRState.IN_XR),
        exitXRAsync: async () => { exits++ },
      },
    })
    let activations = 0
    world.setActionMenu([{ id: 'prove', label: 'Prove a goal', view: 'proof_console' }], () => { activations++ })
    await world.immersive()
    const press = (pressed, axes) => component.onButtonStateChangedObservable.notifyObservers({ pressed, axes })
    press(true, { x: 0, y: -1 })
    component.onAxisValueChangedObservable.notifyObservers({ x: 0, y: 0 })
    press(false, { x: 0, y: 0 })
    const cancelled = activations === 0
    press(true, { x: 0, y: -1 }); press(false, { x: 0, y: -1 })
    world.setWorkspace(model)
    const spatialOpen = !!room.getMeshByName('proof-workspace') && exits === 0
    world.setWorkspace(null)
    const spatialClosed = !room.getMeshByName('proof-workspace') && exits === 0
    changes.notifyObservers(WebXRState.NOT_IN_XR)
    world.dispose()
    return { typed, calls, scrollable, resultText, locked, sameMesh, hidden, retired, frontFacing,
      screenshot, cancelled, activations, spatialOpen, spatialClosed, modes }
}
