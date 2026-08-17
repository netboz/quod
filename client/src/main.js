import { Engine } from '@babylonjs/core/Engines/engine'
import { Scene } from '@babylonjs/core/scene'
import { ArcRotateCamera } from '@babylonjs/core/Cameras/arcRotateCamera'
import { HemisphericLight } from '@babylonjs/core/Lights/hemisphericLight'
import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder'
import { Color3 } from '@babylonjs/core/Maths/math.color'
import { StandardMaterial } from '@babylonjs/core/Materials/standardMaterial'
import { Vector3 } from '@babylonjs/core/Maths/math.vector'
import { PALETTE } from './palette.js'
import {
  clearActiveKeyProvider,
  createKeyProvider,
  hasLocalKeyProvider,
  importEncryptedKeyProvider,
  loadActiveKeyProvider,
  loadLocalKeyProvider,
  localKeyMatches,
  exportEncryptedKeyProvider,
  saveLocalKeyProvider,
  storeActiveKeyProvider,
} from './key-provider.js'
import {
  assertCrypto,
  authenticateKey,
  resolveSignedOperations,
  signedGoal,
} from './signed-client.js'
import { atom, goalText } from './prolog-term.js'
import './style.css'

const canvas = document.querySelector('#world')
const status = document.querySelector('#status')
const xrButton = document.querySelector('#xr')
const identityButton = document.querySelector('#identity')
const unlockButton = document.querySelector('#unlock')
const saveButton = document.querySelector('#save')
const exportButton = document.querySelector('#export')
const importButton = document.querySelector('#import')
const importFile = document.querySelector('#import-file')
const registerButton = document.querySelector('#register')
const signOutButton = document.querySelector('#sign-out')

let identity = null

// One palette for the DOM and the scene.  Shades are scaled from the brand
// values rather than being separate colours.
const navy = Color3.FromHexString(PALETTE.navy)
const greyBlue = Color3.FromHexString(PALETTE.greyBlue)

// The world preview is decoration; signing goals is the product. A browser
// with WebGL disabled or blocklisted must still create keys, log in, and act
// as its user, so nothing below the preview may depend on the scene existing.
let scene = null
let ground = null

function startWorldPreview() {
  const engine = new Engine(canvas, true, { preserveDrawingBuffer: false, stencil: true })
  scene = new Scene(engine)
  const sky = navy.scale(0.34)
  scene.clearColor.set(sky.r, sky.g, sky.b, 1)

  const camera = new ArcRotateCamera(
    'observer',
    -Math.PI / 2.2,
    Math.PI / 2.7,
    12,
    new Vector3(0, 0.5, 0),
    scene,
  )
  camera.lowerRadiusLimit = 5
  camera.upperRadiusLimit = 20
  camera.attachControl(canvas, true)

  const light = new HemisphericLight('sky', new Vector3(0.2, 1, -0.3), scene)
  light.intensity = 0.9

  ground = MeshBuilder.CreateDisc('ground', { radius: 4, tessellation: 80 }, scene)
  ground.rotation.x = Math.PI / 2
  const groundMaterial = new StandardMaterial('ground-material', scene)
  groundMaterial.diffuseColor = greyBlue.scale(0.30)
  groundMaterial.emissiveColor = navy.scale(0.22)
  ground.material = groundMaterial

  // Red action, gold manifested effect, green material state — the semantic
  // triad of doc/client-world-direction.md §6.5, standing in for real entities.
  for (const [index, color] of [
    Color3.FromHexString(PALETTE.red),
    Color3.FromHexString(PALETTE.gold),
    Color3.FromHexString(PALETTE.green),
  ].entries()) {
    const orb = MeshBuilder.CreateSphere(`presence-${index}`, { diameter: 1.15, segments: 32 }, scene)
    const angle = (index / 3) * Math.PI * 2 + 0.4
    orb.position = new Vector3(Math.cos(angle) * 2.2, 0.55, Math.sin(angle) * 2.2)
    const material = new StandardMaterial(`presence-material-${index}`, scene)
    material.diffuseColor = color
    material.emissiveColor = color.scale(0.18)
    orb.material = material
  }

  engine.runRenderLoop(() => scene.render())
  window.addEventListener('resize', () => engine.resize())
}

let worldPreviewNote = ''
try {
  startWorldPreview()
} catch {
  scene = null
  ground = null
  canvas.hidden = true
  xrButton.hidden = true
  worldPreviewNote =
    ' The 3D preview is off because this browser has no WebGL — check hardware acceleration in its settings. Identities and goals are unaffected.'
}

async function updateHealth() {
  try {
    const response = await fetch('/health', { cache: 'no-store' })
    if (!response.ok) throw new Error(`health ${response.status}`)
    status.textContent =
      `This node is ready. You can start a temporary signed identity.${worldPreviewNote}`
  } catch {
    status.textContent =
      `This node is not ready yet. The world preview remains local.${worldPreviewNote}`
  }
}

xrButton.addEventListener('click', async () => {
  if (!scene) {
    status.textContent = 'Immersive mode needs the 3D preview, which this browser cannot start.'
    return
  }
  xrButton.disabled = true
  try {
    // XR is optional and expensive.  Keep it out of the first scene bundle;
    // browsers without WebXR never download it.
    await import('@babylonjs/core/XR/webXRDefaultExperience')
    await scene.createDefaultXRExperienceAsync({ floorMeshes: [ground] })
    status.textContent = 'Immersive mode is ready.'
  } catch {
    status.textContent = 'Immersive mode is not available in this browser or headset.'
  } finally {
    xrButton.disabled = false
  }
})

identityButton.addEventListener('click', async () => {
  await withIdentityButton(identityButton, async () => {
    status.textContent = 'Creating an Ed25519 identity…'
    await authenticate(createKeyProvider())
  })
})

// Leaving is explicit and complete: the browser keeps no identity afterwards,
// so an exported file is the only way back to this user.
signOutButton.addEventListener('click', async () => {
  signOutButton.disabled = true
  try {
    await clearActiveKeyProvider()
  } catch {
    /* nothing kept it; reloading still lands on a signed-out page */
  }
  window.location.reload()
})

unlockButton.addEventListener('click', async () => {
  await withIdentityButton(unlockButton, async () => {
    const passphrase = window.prompt('Passphrase for your saved Quod identity')
    if (passphrase === null) {
      status.textContent = 'Unlock cancelled.'
      unlockButton.disabled = false
      return
    }
    status.textContent = 'Unlocking your saved identity…'
    await authenticate(loadLocalKeyProvider(passphrase))
  })
})

saveButton.addEventListener('click', async () => {
  if (!identity) return
  const passphrase = await confirmedPassphrase('Choose a passphrase for this encrypted key')
  if (passphrase === null) return
  saveButton.disabled = true
  try {
    await saveLocalKeyProvider(identity.provider, passphrase)
    // Read the store back. A browser that silently drops site data would
    // otherwise leave someone believing a key exists that they can never
    // unlock again, here or in the Explorer.
    if (localKeyMatches(identity.provider)) {
      saveButton.textContent = 'Encrypted key saved'
      status.textContent = `Signed in as ${identity.session.user_id.slice(0, 17)}… Your encrypted key is saved on this browser. Unlock this same key in the Explorer to act as the same user there.`
    } else {
      saveButton.disabled = false
      status.textContent =
        'This browser did not keep the encrypted key. Export it to a file instead — private browsing or blocked site data prevents saving.'
    }
  } catch (error) {
    status.textContent = `Could not save the key: ${error.message || 'unknown error'}`
    saveButton.disabled = false
  }
})

exportButton.addEventListener('click', async () => {
  if (!identity) return
  const passphrase = await confirmedPassphrase('Passphrase for the encrypted key file')
  if (passphrase === null) return
  exportButton.disabled = true
  try {
    const encoded = await exportEncryptedKeyProvider(identity.provider, passphrase)
    const blob = new Blob([encoded], { type: 'application/json' })
    const url = URL.createObjectURL(blob)
    const link = document.createElement('a')
    link.href = url
    link.download = `${identity.session.user_id}.quodkey`
    link.click()
    URL.revokeObjectURL(url)
    status.textContent = 'Encrypted key file exported. You may store it on a USB stick.'
  } catch (error) {
    status.textContent = `Could not export the key: ${error.message || 'unknown error'}`
  } finally {
    exportButton.disabled = false
  }
})

importButton.addEventListener('click', () => importFile.click())

importFile.addEventListener('change', async () => {
  const [file] = importFile.files
  importFile.value = ''
  if (!file) return
  if (file.size > 16_384) {
    status.textContent = 'That encrypted key file is too large.'
    return
  }
  const passphrase = window.prompt('Passphrase for the encrypted key file')
  if (passphrase === null) return
  importButton.disabled = true
  try {
    status.textContent = 'Unlocking imported identity…'
    await authenticate(importEncryptedKeyProvider(await file.text(), passphrase))
  } catch (error) {
    status.textContent = `Could not import the key: ${error.message || 'unknown error'}`
  } finally {
    importButton.disabled = false
  }
})

registerButton.addEventListener('click', async () => {
  if (!identity) return
  registerButton.disabled = true
  try {
    status.textContent = 'Creating your user home on this node…'
    const reply = await signedGoal(identity, {
      mode: 'execute',
      namespace: 'quod:root',
      anchor: identity.networkId,
      goal: goalText(atom('create_user_home')),
    })
    if (reply.result === 'ok') {
      registerButton.textContent = 'User home ready'
      status.textContent = `Your user home is ready on this node: ${identity.session.namespace}`
    } else if (reply.result === 'pending') {
      registerButton.textContent = 'Home outcome pending'
      status.textContent = 'The home request may still commit. Do not submit it again; resolve the displayed anchored outcome first.'
    } else if (reply.result === 'fail') {
      throw new Error(reply.reasons?.join('; ') || 'the root ontology refused home creation')
    } else {
      throw new Error(reply.error || 'home creation did not complete')
    }
  } catch (error) {
    if (error.outcomeUnknown) {
      registerButton.textContent = 'Home outcome unknown'
      status.textContent = 'The request may have reached the node. Do not submit it again; resolve its outcome before taking another action.'
    } else {
      status.textContent = `Could not create your user home: ${error.message || 'unknown error'}`
      registerButton.disabled = false
    }
  }
})

async function withIdentityButton(button, operation) {
  button.disabled = true
  try {
    assertKeysUsable()
    await operation()
  } catch (error) {
    status.textContent = `Identity setup failed: ${error.message || 'unknown error'}`
    button.disabled = false
  }
}

// A browser exposes Web Crypto only in a secure context, so an http:// page on
// anything but localhost simply has no crypto.subtle. Naming that cause beats
// reporting "unavailable" and leaving someone to guess at their browser.
function assertKeysUsable() {
  assertCrypto()
}

async function confirmedPassphrase(promptText) {
  const passphrase = window.prompt(`${promptText} (at least 12 characters)`)
  if (passphrase === null) return null
  const confirmation = window.prompt('Repeat the passphrase')
  if (confirmation !== passphrase) {
    status.textContent = 'The passphrases did not match. Nothing was saved.'
    return null
  }
  return passphrase
}

async function authenticate(providerPromise) {
  identity = await authenticateKey(await providerPromise)
  const { provider, session } = identity
  // Keep the identity for the next page and the next visit. Every entry point
  // funnels through here, so creating, unlocking and importing all persist.
  let identityStorageNote = ''
  try {
    await storeActiveKeyProvider(provider)
  } catch {
    identityStorageNote =
      ' This browser will not keep the identity, so it must be imported again next time.'
  }
  let recovered = []
  let journalWarning = ''
  try {
    recovered = await resolveSignedOperations(identity)
  } catch {
    journalWarning = ' Durable write storage is unavailable, so reads remain available but writes are disabled.'
  }
  const unresolved = recovered.filter(({ reply }) => reply?.terminal !== true).length
  // One identity per browser: the ways in are gone once someone is signed in,
  // and the way out is explicit.
  identityButton.hidden = true
  unlockButton.hidden = true
  importButton.hidden = true
  saveButton.hidden = true
  exportButton.hidden = false
  exportButton.disabled = false
  signOutButton.hidden = false
  signOutButton.disabled = false
  registerButton.hidden = false
  registerButton.disabled = journalWarning !== ''
  status.textContent =
    `Signed in as ${session.user_id.slice(0, 17)}…`
    + ` This browser stays signed in, including in the Explorer.`
    + `${unresolved ? ` ${unresolved} earlier write ${unresolved === 1 ? 'is' : 'are'} still unresolved.` : ''}`
    + `${journalWarning || ' You can create its user home here.'}`
    + identityStorageNote
    + worldPreviewNote
}

// Sign in before anything is clicked when this browser already holds the
// identity. Nobody should retype a passphrase to keep being the same user.
async function resumeIdentity() {
  const provider = await loadActiveKeyProvider()
  if (!provider) {
    identityButton.hidden = false
    unlockButton.hidden = !hasLocalKeyProvider()
    importButton.hidden = false
    return
  }
  try {
    status.textContent = 'Signing in with this browser’s identity…'
    await authenticate(Promise.resolve(provider))
  } catch (error) {
    identityButton.hidden = false
    unlockButton.hidden = !hasLocalKeyProvider()
    importButton.hidden = false
    status.textContent =
      `Could not sign in with the stored identity: ${error.message || 'unknown error'}`
  }
}

void updateHealth()
void resumeIdentity()
