import { Engine } from '@babylonjs/core/Engines/engine.js'
import { Scene } from '@babylonjs/core/scene.js'
import { ArcRotateCamera } from '@babylonjs/core/Cameras/arcRotateCamera.js'
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js'
import { createWorkspacePanel } from '../src/workspace-panel.js'
import { createWorld } from '../src/world-scene.js'
import { EngineStore } from '@babylonjs/core/Engines/engineStore.js'
import { Observable } from '@babylonjs/core/Misc/observable.js'
import { WebXRState } from '@babylonjs/core/XR/webXRTypes.js'
import { readGuiView } from '../src/world.js'

export async function exerciseWorkspacePanel() {
  const browserErrors = []
  const error = event => browserErrors.push(String(event.error?.stack ?? event.message))
  const rejection = event => browserErrors.push(String(event.reason?.stack ?? event.reason))
  window.addEventListener('error', error)
  window.addEventListener('unhandledrejection', rejection)
  try {
    const result = await exercisePanel()
    // Drain an actual task boundary, including browser event errors which
    // dispatchEvent reports globally instead of throwing to its caller.
    await new Promise(resolve => {
      const channel = new MessageChannel()
      channel.port1.onmessage = () => {
        channel.port1.close(); channel.port2.close(); resolve()
      }
      channel.port2.postMessage(null)
    })
    return { ...result, browserErrors }
  } finally {
    window.removeEventListener('error', error)
    window.removeEventListener('unhandledrejection', rejection)
  }
}

async function exercisePanel() {
    const engine = new Engine(document.querySelector('canvas'), true, { preserveDrawingBuffer: true })
    const scene = new Scene(engine)
    new ArcRotateCamera('viewer', -Math.PI / 2, Math.PI / 2, 3, Vector3.Zero(), scene)
    const initialMeshes = scene.meshes.length
    const initialObservers = scene.onPointerObservable.hasObservers()
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
    // Drive an actual completed Babylon frame. Offscreen browser sessions can
    // suppress animation-frame callbacks even while the document is visible.
    const rendered = () => new Promise(resolve => {
      scene.onAfterRenderObservable.addOnce(resolve)
      engine.beginFrame(); scene.render(); engine.endFrame()
    })
    const pointAt = (x, y) => {
      const screen = Vector3.Project(new Vector3((x / 1280 - 0.5) * 1.8, (0.5 - y / 1440) * 1.7, 0),
        mesh.getWorldMatrix(), scene.getTransformMatrix(),
        scene.activeCamera.viewport.toGlobal(engine.getRenderWidth(), engine.getRenderHeight()))
      const canvas = engine.getRenderingCanvas(), rect = canvas.getBoundingClientRect()
      return { clientX: rect.left + screen.x / engine.getRenderWidth() * rect.width,
        clientY: rect.top + screen.y / engine.getRenderHeight() * rect.height }
    }
    const pointer = (type, point, buttons) => engine.getRenderingCanvas().dispatchEvent(new PointerEvent(type, {
      ...point, bubbles: true, pointerId: 1, pointerType: 'mouse', button: type === 'pointermove' ? -1 : 0, buttons,
    }))
    await scene.whenReadyAsync()
    await rendered()
    const initialBackground = texture.background
    const opacity = texture.getControlByName('workspace-opacity')
    opacity.value = 0.6
    const translucentBackground = texture.background
    click('workspace-opaque')
    const opaqueBackground = texture.background
    click('workspace-opacity-less')
    const steppedOpacity = opacity.value
    opacity.value = 0.78
    texture.focusedControl = editor
    for (const key of ['a', '(', '⇧', 'x', ')', '.']) keyboard.onKeyPressObservable.notifyObservers(key)
    const typed = model.values.goal
    click('run'); click('accept')
    model.locked = true
    model.enabled = { run: false, next: true, accept: true, stop: true }
    model.values.results = Array.from({ length: 60 }, (_, i) => `Binding${i} = value(${i})`).join('\n')
    panel.update(model, true)
    click('run'); click('next'); click('accept'); click('stop'); click('close')
    engine.getRenderingCanvas().dispatchEvent(new KeyboardEvent('keydown', {
      key: 'z', code: 'KeyZ', keyCode: 90, bubbles: true,
    }))
    await rendered()
    const scroll = texture.getControlByName('results-scroll')
    const scrollable = scroll.verticalBar.isVisible
    const resultText = texture.getControlByName('results').text
    const locked = !editor.isEnabled && !keyboard.isEnabled &&
      texture.focusedControl === null && editor.text === model.values.goal
    const opaqueControls = editor.alpha === 1 &&
      texture.getControlByName('run').alpha === 1 && scroll.background === '#0F1B20'
    // A code eidolon uses the same renderer and plane. Replacing its schema
    // must retire the old controls and reconnect the keyboard to the new editor.
    model.view = { title: 'Prolog code', fields: [
      { role: 'predicate', kind: 'catalogue_selection', label: 'Predicate' },
      { role: 'new_predicate', kind: 'text_box', label: 'New predicate (name/arity)' },
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
      { kind: 'catalogue_selection', role: 'layout', label: 'Code layout' },
      { kind: 'catalogue_selection', role: 'clause', label: 'Clause order' },
      { kind: 'text_box', role: 'head', label: 'Head' },
      { kind: 'editor', role: 'body', label: 'Body (empty for a fact)' },
      ...['add_clause', 'remove_clause', 'move_up', 'move_down'].map(role => ({ kind: 'button', role, label: role })),
    ]) }
    model.values = { ...model.values, layout: 'cards', clause: '0', head: 'p(a)', body: 'true' }
    model.choices = { ...model.choices, layout: [{ value: 'cards', label: 'Clause cards' }],
      clause: [{ value: '0', label: '1. p(a)' }] }
    panel.update(model, true)
    await rendered()
    const cardsScrollable = texture.getControlByName('workspace-scroll').verticalBar.isVisible
    const sourceRetired = texture.getControlByName('source') === null &&
      sourceEditor.onTextChangedObservable.observers.length === 0 &&
      texture.focusedControl === null && !keyboard.isVisible
    const actionBounds = ['run', 'accept', 'stop', 'create', 'resolve',
      'add_clause', 'remove_clause', 'move_up', 'move_down', 'close-workspace'].map(role => {
      const { left, top, width, height } = texture.getControlByName(role)._currentMeasure
      return { left, right: left + width, top, bottom: top + height }
    })
    model.locked = true
    panel.update(model, true)
    click('predicate-next')
    const lockedChoice = model.values.predicate === 'rule/2'
    model.view = readGuiView(`component(instrument,form,[property(label,<<"Instrument settings">>)],[
      component(name,text_box,[property(label,<<"Instrument name">>),property(required,true),property(max_bytes,12)],[]),
      component(mode,selection,[property(label,<<"Mode">>),property(options,[
        option(mode(review),<<"Review">>),option(mode(run),<<"Run">>)])],[]),
      component(settings,container,[property(label,<<"Settings">>),property(layout,row)],[
        component(gain,slider,[property(label,<<"Gain">>),property(unit,<<"dB">>),property(range,range(3,14,4))],[]),
        component(angle,rotary_knob,[property(label,<<"Angle">>),property(unit,degrees),property(range,range(-30,30,5))],[])]),
      component(fixed,container,[property(label,<<"Fixed">>),property(enabled,false)],[
        component(frozen,slider,[property(label,<<"Frozen">>),property(range,range(0,10,1))],[])]),
      component(apply,button,[property(label,<<"Apply settings">>)],[])])`)
    model.values = { name: 'Spectrum', mode: 'mode(review)', gain: '3', angle: '0', frozen: '5' }
    model.enabled = { apply: true }
    model.locked = false
    panel.update(model, true)
    await rendered()
    click('mode-next')
    const semanticSelection = model.values.mode
    texture.getControlByName('name').text = ''
    const requiredFeedback = texture.getControlByName('name-error').isVisible && model.values.name === ''
    texture.getControlByName('name').text = '🎛🎛🎛🎛'
    const byteFeedback = texture.getControlByName('name-error').text === '16 bytes; maximum 12.'
    texture.getControlByName('name').text = 'Spectrum 2'
    const commonText = model.values.name
    const plusBox = texture.getControlByName('gain-more')._currentMeasure
    const plusPoint = pointAt(plusBox.left + plusBox.width / 2, plusBox.top + plusBox.height / 2)
    pointer('pointermove', plusPoint, 0)
    pointer('pointerdown', plusPoint, 1)
    pointer('pointerup', plusPoint, 0)
    await rendered()
    const steppedGain = model.values.gain
    const gain = texture.getControlByName('gain-slider')
    gain.value = 14
    const clampedGain = model.values.gain
    const number = texture.getControlByName('gain-number')
    number.text = '8'
    const invalidDraftRetained = model.values.gain === '8' &&
      texture.getControlByName('gain-error').isVisible && number.isEnabled && !gain.isEnabled && !gain.isVisible
    number.text = '3'
    const numericEntry = model.values.gain
    const dial = texture.getControlByName('angle-dial')
    const { left: dialLeft, top: dialTop } = dial._currentMeasure
    pointer('pointerdown', pointAt(dialLeft + 70, dialTop + 8), 1)
    pointer('pointermove', pointAt(dialLeft + 132, dialTop + 70), 1)
    // A fixed screen corner can still hit this large panel at a narrow aspect
    // ratio. Establish that the release ray actually misses the panel.
    const canvasRect = engine.getRenderingCanvas().getBoundingClientRect()
    const outside = { clientX: canvasRect.left - canvasRect.width, clientY: canvasRect.top - canvasRect.height }
    const outsideMesh = !scene.pick(-canvasRect.width, -canvasRect.height, candidate => candidate === mesh)?.hit
    pointer('pointerup', outside, 0)
    const rotatedAngle = model.values.angle
    pointer('pointermove', pointAt(dialLeft + 70, dialTop + 8), 0)
    const releasedOutside = model.values.angle === rotatedAngle
    click('angle-less')
    const steppedAngle = model.values.angle
    click('frozen-more')
    const frozenNumeric = model.values.frozen === '5' && !texture.getControlByName('frozen-number').isEnabled
    model.locked = true
    panel.update(model, true)
    click('angle-more')
    const lockedNumeric = model.values.angle === steppedAngle && !dial.isEnabled
    model.locked = false
    panel.update(model, true)
    await rendered()
    const numericBounds = ['gain', 'angle', 'gain-number', 'angle-number'].map(role => {
      const { left, top, width, height } = texture.getControlByName(role)._currentMeasure
      return { left, right: left + width, top, bottom: top + height }
    })
    const screenshot = engine.getRenderingCanvas().toDataURL('image/png')
    delete model.values.gain
    panel.update(model, true)
    const missingNumeric = number.text === '' && !gain.isEnabled && !gain.isVisible && texture.getControlByName('gain-error').isVisible
    model.view = { title: 'Many actions', fields: [
      { kind: 'text_box', role: 'caption', label: 'Caption' },
      ...Array.from({ length: 22 }, (_, n) => ({ kind: 'button', role: `action-${n}`, label: `Action ${n}` })),
    ] }
    model.values = { caption: '' }
    model.enabled = Object.fromEntries(Array.from({ length: 22 }, (_, n) => [`action-${n}`, true]))
    panel.update(model, true)
    texture.focusedControl = texture.getControlByName('caption')
    await rendered()
    const actionScroll = texture.getControlByName('workspace-action-scroll')
    const actionsScrollable = actionScroll.verticalBar.isVisible
    actionScroll.verticalBar.value = 1
    await rendered()
    const last = texture.getControlByName('action-21')._currentMeasure
    const actionArea = actionScroll._currentMeasure
    const lastActionReachable = last.top >= actionArea.top && last.top + last.height <= actionArea.top + actionArea.height
    const keyboardArea = keyboard._currentMeasure
    const keyboardInsideTexture = keyboard.isVisible && keyboardArea.top >= 0 && keyboardArea.top + keyboardArea.height <= 1440
    model.view = { title: 'Placement and scale', fields: [{ kind: 'container', role: 'scale-row',
      label: 'Fields', layout: 'row', children: [
        { kind: 'text_box', role: 'left', label: 'Left' }, { kind: 'text_box', role: 'right', label: 'Right' },
      ] }] }
    model.values = { left: 'Kept left', right: 'Kept right' }
    panel.update(model, true)
    await rendered()
    const scaleDraft = JSON.stringify(model.values)
    click('workspace-text-larger')
    await rendered()
    const largerTextReflows = mesh.scaling.x === 1.25 &&
      texture.getControlByName('right')._currentMeasure.top > texture.getControlByName('left')._currentMeasure.top &&
      JSON.stringify(model.values) === scaleDraft
    click('workspace-text-smaller')
    await rendered()
    const smallerTextRestoresRows = mesh.scaling.x === 1 &&
      texture.getControlByName('right')._currentMeasure.top === texture.getControlByName('left')._currentMeasure.top
    const stablePosition = mesh.position.clone()
    scene.activeCamera.alpha += 0.3
    await rendered()
    const worldStable = mesh.position.equalsWithEpsilon(stablePosition)
    click('workspace-recenter')
    const recentered = !mesh.position.equalsWithEpsilon(stablePosition) &&
      Math.abs(Vector3.Distance(mesh.position, scene.activeCamera.globalPosition) - 1.6) < 0.001
    click('workspace-farther')
    const farther = Math.abs(Vector3.Distance(mesh.position, scene.activeCamera.globalPosition) - 1.8) < 0.001
    click('workspace-nearer')
    click('workspace-move')
    const beforeMove = mesh.position.clone()
    scene.activeCamera.alpha += 0.3
    await rendered()
    const moved = !mesh.position.equalsWithEpsilon(beforeMove)
    click('workspace-move')
    const placed = mesh.position.clone()
    scene.activeCamera.alpha += 0.3
    await rendered()
    const placedStaysStill = moved && mesh.position.equalsWithEpsilon(placed)
    click('workspace-move')
    const sameMesh = mesh === scene.getMeshByName('workspace')
    panel.update(model, false)
    const hidden = !mesh.isVisible && !mesh.isPickable && texture.focusedControl === null
    scene.activeCamera.alpha += 0.3
    await rendered()
    const movementStopsOnHide = mesh.position.equalsWithEpsilon(placed)
    panel.update(model, true)
    await rendered()
    panel.dispose()
    await rendered()
    const retired = scene.meshes.length === initialMeshes &&
      // Babylon marks observers inactive immediately, then compacts its array
      // in a later task. The public predicate checks actual callback liveness.
      scene.onPointerObservable.hasObservers() === initialObservers
    scene.dispose(); engine.dispose()
    // Feed controller and XR lifecycle notices into the real world adapter.
    // This tests wiring; it does not claim physical-headset acceptance.
    const modes = []
    const world = createWorld(document.querySelector('canvas'), () => {}, value => modes.push(value))
    const room = EngineStore.LastCreatedScene
    room.activeCamera.getViewMatrix(true)
    room.activeCamera.trackingState = 0
    room.activeCamera.onTrackingStateChanged = new Observable()
    const component = { pressed: false, onAxisValueChangedObservable: new Observable(),
      onButtonStateChangedObservable: new Observable() }
    const changes = new Observable()
    let exits = 0
    const { WebXRDefaultExperience } = await import('@babylonjs/core/XR/webXRDefaultExperience.js')
    const createXR = WebXRDefaultExperience.CreateAsync
    WebXRDefaultExperience.CreateAsync = async () => ({
      input: { controllers: [{ inputSource: { handedness: 'right' },
        motionController: { getComponentOfType: () => component } }],
        onControllerAddedObservable: new Observable(), onControllerRemovedObservable: new Observable() },
      baseExperience: { camera: room.activeCamera, onStateChangedObservable: changes,
        enterXRAsync: async () => changes.notifyObservers(WebXRState.IN_XR),
        exitXRAsync: async () => { exits++ },
      },
    })
    let activations = 0
    world.setActionMenu([{ id: 'prove', label: 'Prove a goal', view: 'proof_console' }], () => { activations++ })
    try { await world.immersive() }
    finally { WebXRDefaultExperience.CreateAsync = createXR }
    world.setWorkspace(model)
    const waitsForTracking = !room.getMeshByName('workspace')
    room.activeCamera.trackingState = 2
    room.activeCamera.onTrackingStateChanged.notifyObservers(2)
    world.setWorkspace(null)
    room.render()
    const closedDuringTrackingWait = !room.getMeshByName('workspace')
    room.activeCamera.trackingState = 0
    world.setWorkspace(model)
    room.activeCamera.trackingState = 2
    room.activeCamera.onTrackingStateChanged.notifyObservers(2)
    room.activeCamera.position.set(4, 1.8, -2)
    room.render()
    const placedAfterPose = Math.abs(Vector3.Distance(room.getMeshByName('workspace').position,
      room.activeCamera.globalPosition) - 1.6) < 0.001
    world.setWorkspace(null)
    const press = (pressed, axes) => component.onButtonStateChangedObservable.notifyObservers({ pressed, axes })
    press(true, { x: 0, y: -1 })
    const facesViewer = node => {
      node.computeWorldMatrix(true)
      return Vector3.Dot(node.getDirection(new Vector3(0, 0, 1)),
        room.activeCamera.globalPosition.subtract(node.position)) > 0 &&
        Vector3.Dot(node.getDirection(new Vector3(1, 0, 0)),
          room.activeCamera.getDirection(new Vector3(1, 0, 0))) > 0 &&
        Vector3.Dot(node.getDirection(new Vector3(0, 1, 0)),
          room.activeCamera.getDirection(new Vector3(0, 1, 0))) > 0
    }
    const rightHandedMenu = facesViewer(room.getTransformNodeByName('action-menu'))
    component.onAxisValueChangedObservable.notifyObservers({ x: 0, y: 0 })
    press(false, { x: 0, y: 0 })
    const cancelled = activations === 0
    press(true, { x: 0, y: -1 }); press(false, { x: 0, y: -1 })
    world.setWorkspace(model)
    const spatialOpen = !!room.getMeshByName('workspace') && exits === 0
    const rightHandedPanel = facesViewer(room.getMeshByName('workspace'))
    const { SceneLoader } = await import('@babylonjs/core/Loading/sceneLoader.js')
    const controllerLoader = SceneLoader.IsPluginForExtensionAvailable('.babylon')
    const gltfControllerLoader = SceneLoader.IsPluginForExtensionAvailable('.glb')
    const { WebXRFeaturesManager } = await import('@babylonjs/core/XR/webXRFeaturesManager.js')
    const xrFeatures = ['xr-controller-pointer-selection', 'xr-near-interaction', 'xr-hand-tracking']
      .every(name => WebXRFeaturesManager.GetAvailableFeatures().includes(name))
    // XR touch markers parse serialized node materials. Class availability
    // alone does not establish that their graph can be reconstructed and built.
    const { NodeMaterial } = await import('@babylonjs/core/Materials/Node/nodeMaterial.js')
    const originalMaterial = new NodeMaterial('xr-marker-original', room)
    originalMaterial.setToDefault()
    const restoredMaterial = new NodeMaterial('xr-marker-restored', room)
    restoredMaterial.parseSerializedObject(originalMaterial.serialize())
    const nodeMaterialRoundtrip = await new Promise((resolve, reject) => {
      restoredMaterial.onBuildObservable.addOnce(() => resolve(true))
      restoredMaterial.onBuildErrorObservable.addOnce(reject)
      restoredMaterial.build()
    })
    originalMaterial.dispose(); restoredMaterial.dispose()
    room.getMeshByName('workspace').material.emissiveTexture
      .getControlByName('workspace-text-larger').onPointerClickObservable.notifyObservers({})
    world.setWorkspace(null)
    const spatialClosed = !room.getMeshByName('workspace') && exits === 0
    world.setWorkspace(model)
    const scaleSurvivesReopen = room.getMeshByName('workspace').scaling.x === 1.25
    world.setWorkspace(null)
    changes.notifyObservers(WebXRState.NOT_IN_XR)
    world.dispose()
    return { typed, calls, scrollable, resultText, locked, sameMesh, hidden, retired, frontFacing,
      screenshot, cancelled, activations, spatialOpen, spatialClosed, modes,
      rightHandedMenu, rightHandedPanel, controllerLoader, gltfControllerLoader, xrFeatures,
      nodeMaterialRoundtrip, waitsForTracking, closedDuringTrackingWait, placedAfterPose,
      largerTextReflows, smallerTextRestoresRows, worldStable, recentered, farther,
      placedStaysStill, movementStopsOnHide, scaleSurvivesReopen,
      oldControlsRetired, choices, choiceLabel, multilineSource, lockedChoice, newPredicate, actionBounds, cardsScrollable, sourceRetired,
      initialBackground, translucentBackground, opaqueBackground, steppedOpacity, opaqueControls,
      steppedGain, clampedGain, invalidDraftRetained, numericEntry, rotatedAngle, steppedAngle,
      frozenNumeric, lockedNumeric, numericBounds, semanticSelection, commonText, missingNumeric,
      actionsScrollable, lastActionReachable, keyboardInsideTexture, requiredFeedback, byteFeedback, releasedOutside, outsideMesh }
}
