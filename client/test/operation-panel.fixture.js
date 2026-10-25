// Software XR lifecycle only. The normal World component, workspace panel,
// operation controller and signed endpoint remain the production implementations.
import { EngineStore } from '@babylonjs/core/Engines/engineStore.js'
import { Observable } from '@babylonjs/core/Misc/observable.js'
import { WebXRState, WebXRTrackingState } from '@babylonjs/core/XR/webXRTypes.js'
import { WebXRDefaultExperience } from '@babylonjs/core/XR/webXRDefaultExperience.js'
import { readList } from '../src/prolog-read.js'
import { b64url } from '../src/key-provider.js'
import { renderTerm } from '../src/prolog-term.js'

export function installSoftwareXR() {
  const original = WebXRDefaultExperience.CreateAsync
  WebXRDefaultExperience.CreateAsync = async scene => {
    WebXRDefaultExperience.CreateAsync = original
    const changes = new Observable(), camera = scene.activeCamera
    camera.trackingState = WebXRTrackingState.TRACKING
    camera.onTrackingStateChanged = new Observable()
    return { input: { controllers: [], onControllerAddedObservable: new Observable(),
      onControllerRemovedObservable: new Observable() }, baseExperience: {
      camera, onStateChangedObservable: changes,
      enterXRAsync: async () => changes.notifyObservers(WebXRState.IN_XR),
      exitXRAsync: async () => changes.notifyObservers(WebXRState.NOT_IN_XR),
    } }
  }
}

export function spatialSubmit(role) {
  const scene = EngineStore.LastCreatedScene
  const control = scene.getMeshByName('workspace')?.material.emissiveTexture.getControlByName(role)
  if (!control?.isEnabled) throw new Error('The spatial submit control is not enabled.')
  control.onPointerClickObservable.notifyObservers({})
}

export function spatialType(role, key) {
  const scene = EngineStore.LastCreatedScene, mesh = scene.getMeshByName('workspace')
  const texture = mesh.material.emissiveTexture, control = texture.getControlByName(role)
  texture.focusedControl = control
  const position = mesh.position.clone()
  texture.getControlByName('workspace-keyboard').onKeyPressObservable.notifyObservers(key)
  const value = control.text
  return new Promise((resolve, reject) => {
    const observer = scene.onAfterRenderObservable.add(() => {
      if (![...document.querySelectorAll('input')].some(input => input.value === value)) return
      clearTimeout(timer); scene.onAfterRenderObservable.remove(observer)
      if (scene.getMeshByName('workspace') !== mesh || texture.getControlByName(role) !== control ||
          texture.focusedControl !== control || !mesh.position.equals(position)) {
        reject(new Error('Spatial editing replaced or moved the active panel/control.'))
      } else resolve(value)
    })
    const timer = setTimeout(() => {
      scene.onAfterRenderObservable.remove(observer)
      reject(new Error('Virtual keyboard input did not reach the controller draft.'))
    }, 15000)
  })
}

export function renderedSubject(results) {
  const subject = readList(results).find(row => row.functor === 'result' && row.args[0].value === 'space').args[1]
  const [namespace, anchor, entity] = subject.args
  const scene = EngineStore.LastCreatedScene
  return new Promise((resolve, reject) => {
    const observer = scene.onAfterRenderObservable.add(() => {
      const node = scene.transformNodes.find(node => {
        const depicts = node.metadata?.depicts
        return depicts?.ontology === new TextDecoder().decode(namespace.value) &&
          b64url(depicts.anchor) === b64url(anchor.value) && renderTerm(depicts.entity) === renderTerm(entity)
      })
      if (!node) return
      clearTimeout(timer); scene.onAfterRenderObservable.remove(observer)
      resolve({ position: node.position.asArray(), boxes: node.getChildMeshes().filter(mesh => mesh.getTotalVertices() > 0).length })
    })
    const timer = setTimeout(() => {
      scene.onAfterRenderObservable.remove(observer)
      reject(new Error('The created subject did not reach the rendered scene.'))
    }, 15000)
  })
}
