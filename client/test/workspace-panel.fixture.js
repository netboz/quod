import { Engine } from '@babylonjs/core/Engines/engine.js'
import { Scene } from '@babylonjs/core/scene.js'
import { ArcRotateCamera } from '@babylonjs/core/Cameras/arcRotateCamera.js'
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js'
import { createWorkspacePanel } from '../src/workspace-panel.js'
import { createWorld } from '../src/world-scene.js'
import { EngineStore } from '@babylonjs/core/Engines/engineStore.js'
import { Observable } from '@babylonjs/core/Misc/observable.js'
import { WebXRState } from '@babylonjs/core/XR/webXRTypes.js'

export async function exerciseWorkspacePanel() {
    const engine = new Engine(document.querySelector('canvas'), true, { preserveDrawingBuffer: true })
    const scene = new Scene(engine)
    new ArcRotateCamera('viewer', -Math.PI / 2, Math.PI / 2, 3, Vector3.Zero(), scene)
    const initialMeshes = scene.meshes.length
    const initialObservers = scene.onPointerObservable.observers.length
    const panel = createWorkspacePanel(scene)
    const calls = []
    const model = {
      view: { title: 'Prolog console', fields: [
        { role: 'goal', kind: 'editor', label: 'Prolog goal' },
        { role: 'results', kind: 'bindings', label: 'Bindings' },
        ...['run', 'next', 'accept', 'stop', 'resolve'].map(role => ({ role, kind: 'button', label: role })),
      ] },
      scope: 'human:test', values: { goal: '', results: '' }, locked: false,
      enabled: { run: true, next: false, accept: false, stop: false },
      edit(role, value) { model.values[role] = value; panel.update(model, true) },
      invoke(role) { calls.push(role) },
      close() { calls.push('close') },
    }
    scene.activeCamera.getViewMatrix(true)
    panel.update(model, true)
    const mesh = scene.getMeshByName('workspace')
    mesh.computeWorldMatrix(true)
    const frontFacing = Vector3.Dot(mesh.getDirection(new Vector3(0, 0, -1)),
      scene.activeCamera.globalPosition.subtract(mesh.position)) > 0
    const texture = mesh.material.emissiveTexture
    const editor = texture.getControlByName('goal')
    const keyboard = texture.getControlByName('workspace-keyboard')
    const click = role => texture.getControlByName(role === 'close' ? 'close-workspace' : role).onPointerClickObservable.notifyObservers({})
    engine.runRenderLoop(() => scene.render())
    const rendered = () => new Promise(resolve => scene.onAfterRenderObservable.addOnce(resolve))
    await scene.whenReadyAsync()
    await rendered()
    texture.focusedControl = editor
    for (const key of ['a', '(', '⇧', 'x', ')', '.']) keyboard.onKeyPressObservable.notifyObservers(key)
    const typed = model.values.goal
    click('run'); click('accept')
    model.locked = true
    model.enabled = { run: false, next: true, accept: true, stop: true }
    model.values.results = Array.from({ length: 60 }, (_, i) => `Binding${i} = value(${i})`).join('\n')
    panel.update(model, true)
    click('run'); click('next'); click('accept'); click('stop'); click('close')
    await rendered()
    const scroll = texture.getControlByName('results-scroll')
    const scrollable = scroll.verticalBar.isVisible
    const resultText = texture.getControlByName('results').text
    const locked = !editor.isEnabled && !keyboard.isEnabled
    // A code eidolon uses the same renderer and plane. Replacing its schema
    // must retire the old controls and reconnect the keyboard to the new editor.
    model.view = { title: 'Prolog code', fields: [
      { role: 'predicate', kind: 'choice', label: 'Predicate' },
      { role: 'new_predicate', kind: 'input', label: 'New predicate (name/arity)' },
      { role: 'source', kind: 'editor', label: 'Source code' },
      { role: 'results', kind: 'bindings', label: 'Edit result' },
      ...['run', 'accept', 'stop', 'create', 'resolve'].map(role => ({ role, kind: 'button', label: role })),
    ] }
    model.locked = false
    model.values = { predicate: 'sample/1', new_predicate: '', source: '', results: '' }
    model.enabled = { run: true, accept: true, stop: true, create: true, resolve: true }
    model.choices = { predicate: [
      { value: 'sample/1', label: 'sample / 1' }, { value: 'rule/2', label: 'rule / 2' },
    ] }
    panel.update(model, true)
    await rendered()
    const oldControlsRetired = texture.getControlByName('goal') === null &&
      texture.getControlByName('next') === null && editor.onTextChangedObservable.observers.length === 0
    const choices = []
    for (const direction of ['next', 'next', 'previous']) {
      click(`predicate-${direction}`)
      choices.push(model.values.predicate)
    }
    const choiceLabel = texture.getControlByName('predicate-value').text
    const predicateInput = texture.getControlByName('new_predicate')
    texture.focusedControl = predicateInput
    for (const key of ['f', 'r', 'e', 's', 'h', '/', '2']) keyboard.onKeyPressObservable.notifyObservers(key)
    const newPredicate = model.values.new_predicate
    click('create'); click('resolve')
    const sourceEditor = texture.getControlByName('source')
    texture.focusedControl = sourceEditor
    for (const key of ['p', '(', 'a', ')', '.', '↵', 'q', '(', 'b', ')', '.']) {
      keyboard.onKeyPressObservable.notifyObservers(key)
    }
    const multilineSource = model.values.source
    model.view = { ...model.view, fields: model.view.fields.flatMap(field => field.role !== 'source' ? [field] : [
      { kind: 'choice', role: 'layout', label: 'Code layout' },
      { kind: 'choice', role: 'clause', label: 'Clause order' },
      { kind: 'input', role: 'head', label: 'Head' },
      { kind: 'editor', role: 'body', label: 'Body (empty for a fact)' },
      ...['add_clause', 'remove_clause', 'move_up', 'move_down'].map(role => ({ kind: 'button', role, label: role })),
    ]) }
    model.values = { ...model.values, layout: 'cards', clause: '0', head: 'p(a)', body: 'true' }
    model.choices = { ...model.choices, layout: [{ value: 'cards', label: 'Clause cards' }],
      clause: [{ value: '0', label: '1. p(a)' }] }
    panel.update(model, true)
    await rendered()
    const cardsScrollable = texture.getControlByName('workspace-scroll').verticalBar.isVisible
    const sourceRetired = texture.getControlByName('source') === null && sourceEditor.onTextChangedObservable.observers.length === 0
    const actionBounds = ['run', 'accept', 'stop', 'create', 'resolve',
      'add_clause', 'remove_clause', 'move_up', 'move_down', 'close-workspace'].map(role => {
      const { left, top, width, height } = texture.getControlByName(role)._currentMeasure
      return { left, right: left + width, top, bottom: top + height }
    })
    model.locked = true
    panel.update(model, true)
    click('predicate-next')
    const lockedChoice = model.values.predicate === 'rule/2'
    const sameMesh = mesh === scene.getMeshByName('workspace')
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
    const spatialOpen = !!room.getMeshByName('workspace') && exits === 0
    world.setWorkspace(null)
    const spatialClosed = !room.getMeshByName('workspace') && exits === 0
    changes.notifyObservers(WebXRState.NOT_IN_XR)
    world.dispose()
    return { typed, calls, scrollable, resultText, locked, sameMesh, hidden, retired, frontFacing,
      screenshot, cancelled, activations, spatialOpen, spatialClosed, modes,
      oldControlsRetired, choices, choiceLabel, multilineSource, lockedChoice, newPredicate, actionBounds, cardsScrollable, sourceRetired }
}
