// Scene-owned engine resources, keyed by content and binding. Ontologies choose
// assets; this owner verifies and loads them, never interprets domain state.
import { Texture } from '@babylonjs/core/Materials/Textures/texture.js'
import { validateGlb, checkGlbCosts } from './glb-profile.js'

export function createRenderResources(scene, {
  fetchAsset = (url, options) => fetch(url, options),
  decode = (bytes, identity) => decodeTexture(scene, bytes, identity),
  decodeModel = async bytes => {
    await import('@babylonjs/loaders/glTF/2.0/glTFLoader.js')
    const { LoadAssetContainerAsync } = await import('@babylonjs/core/Loading/sceneLoader.js')
    return LoadAssetContainerAsync(new Uint8Array(bytes), scene,
      { pluginExtension: '.glb', name: 'verified.glb' })
  },
} = {}) {
  const assets = new Map()
  const bindings = new Map()
  const models = new Map()
  let disposed = false

  function acquireBytes(kind, digest, maximum = Infinity) {
    const key = `${kind}:${digest}`
    let asset = assets.get(key)
    if (!asset) {
      const controller = new AbortController()
      asset = { users: 0, controller, maximum,
        ready: verifiedBytes(kind, digest, controller.signal, fetchAsset,
          () => asset.maximum).catch(error => {
            if (assets.get(key) === asset) assets.delete(key)
            throw error
          }) }
      assets.set(key, asset)
    }
    asset.maximum = Math.max(asset.maximum, maximum)
    asset.users++
    return { asset, release() {
      if (--asset.users === 0) {
        asset.controller.abort()
        if (assets.get(key) === asset) assets.delete(key)
      }
    } }
  }

  function acquire(binding) {
    if (disposed) throw new Error('render resources are disposed')
    const { digest, slot, repeat } = binding
    const key = JSON.stringify([digest, slot, repeat])
    let entry = bindings.get(key)
    if (!entry) {
      const bytes = acquireBytes('texture', digest)
      entry = { users: 0, active: true, texture: null, bytes }
      entry.ready = bytes.asset.ready.then(async data => {
        if (!entry.active) return null
        const loading = decode(data, key)
        entry.texture = loading.texture
        if (!entry.active) { loading.texture.dispose(); return null }
        await loading.ready
        if (!entry.active) return null
        const texture = entry.texture
        texture.gammaSpace = slot === 'base_colour'
        texture.uScale = repeat[0]
        texture.vScale = repeat[1]
        texture.wrapU = Texture.WRAP_ADDRESSMODE
        texture.wrapV = Texture.WRAP_ADDRESSMODE
        return texture
      })
      bindings.set(key, entry)
    }
    entry.users++
    let released = false
    return {
      ready: entry.ready,
      release() {
        if (released) return
        released = true
        if (--entry.users === 0) retire(key, entry)
      },
    }
  }

  function retire(key, entry) {
    if (!entry.active) return
    entry.active = false
    bindings.delete(key)
    entry.texture?.dispose()
    entry.bytes.release()
  }

  function acquireModel({ digest, profile, allowed, bounds }) {
    if (disposed) throw new Error('render resources are disposed')
    if (profile !== 'gltf2-static-v1') throw new Error('unsupported mesh profile')
    const key = `${profile}:${digest}`
    let entry = models.get(key)
    if (!entry) {
      const bytes = acquireBytes('model', digest, allowed[0])
      entry = { users: new Set(), active: true, container: null, bytes }
      entry.ready = bytes.asset.ready.then(async data => {
        if (!entry.active) return null
        const { costs, boundsMm } = validateGlb(data)
        entry.costs = costs
        entry.boundsMm = boundsMm
        // No template is decoded unless at least one current, authorized
        // occurrence can afford the measured asset.
        if (![...entry.users].some(user => permits(costs, user.allowed) &&
          sameBounds(boundsMm, user.bounds))) {
          const first = [...entry.users][0]
          checkGlbCosts(costs, first.allowed)
          checkBounds(boundsMm, first.bounds)
        }
        const container = await decodeModel(data)
        if (!entry.active) { container.dispose(); return null }
        entry.container = container
        return container
      }).catch(error => {
        if (models.get(key) === entry) models.delete(key)
        throw error
      })
      models.set(key, entry)
    } else {
      entry.bytes.asset.maximum = Math.max(entry.bytes.asset.maximum, allowed[0])
    }
    const user = { allowed, bounds }
    entry.users.add(user)
    let released = false
    return {
      ready: entry.ready.then(container => {
        if (!container || released) return null
        checkGlbCosts(entry.costs, allowed)
        checkBounds(entry.boundsMm, bounds)
        return container
      }),
      release() {
        if (released) return
        released = true
        entry.users.delete(user)
        if (entry.users.size === 0) retireModel(key, entry)
      },
    }
  }

  function retireModel(key, entry) {
    if (!entry.active) return
    entry.active = false
    if (models.get(key) === entry) models.delete(key)
    entry.container?.dispose()
    entry.bytes.release()
  }

  return {
    acquire,
    acquireModel,
    dispose() {
      disposed = true
      for (const [key, entry] of bindings) retire(key, entry)
      for (const [key, entry] of models) retireModel(key, entry)
    },
  }
}

function permits(costs, allowed) {
  return Array.isArray(allowed) && costs.every((cost, i) => cost <= allowed[i])
}

function sameBounds(actual, declared) {
  return Array.isArray(declared) && declared.length === 6 &&
    actual.every((value, i) => value === declared[i])
}

function checkBounds(actual, declared) {
  if (!sameBounds(actual, declared)) {
    throw new Error(`asset-local bounds differ from verified GLB: ${actual.join(',')}`)
  }
}

async function verifiedBytes(kind, digest, signal, fetchAsset, maximum) {
  const path = kind === 'model' ? `/assets/models/${digest}.glb`
    : `/assets/textures/${digest}.jpg`
  const response = await fetchAsset(path, { signal })
  if (!response.ok) throw new Error(`${kind} ${digest}: HTTP ${response.status}`)
  let bytes
  if (response.body?.getReader) {
    const reader = response.body.getReader(), chunks = []
    let length = 0
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      length += value.length
      if (length > maximum()) { await reader.cancel(); throw new Error(`${kind} transfer bytes exceeded`) }
      chunks.push(value)
    }
    bytes = new Uint8Array(length)
    let at = 0
    for (const chunk of chunks) { bytes.set(chunk, at); at += chunk.length }
  } else {
    bytes = new Uint8Array(await response.arrayBuffer())
    if (bytes.length > maximum()) throw new Error(`${kind} transfer bytes exceeded`)
  }
  const hash = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))
  const actual = [...hash].map(n => n.toString(16).padStart(2, '0')).join('')
  if (actual !== digest) throw new Error(`${kind} ${digest}: content digest mismatch`)
  return bytes
}

function decodeTexture(scene, bytes, identity) {
  let texture, bitmap, active = true
  const ready = new Promise((resolve, reject) => {
    texture = new Texture(null, scene, false, false, Texture.TRILINEAR_SAMPLINGMODE,
      resolve, message => reject(new Error(`texture decode failed: ${message}`)))
    texture.onDisposeObservable.addOnce(() => {
      active = false
      bitmap?.close()
      reject(new Error('texture released during decode'))
    })
    // Decode verified bytes directly. No blob URL or extra image fetch; the
    // bitmap stays owned by the texture for WebGL context restoration.
    createImageBitmap(new Blob([bytes], { type: 'image/jpeg' }),
      { colorSpaceConversion: 'none', imageOrientation: 'none', premultiplyAlpha: 'none' })
      .then(image => {
        if (!active) { image.close(); return }
        bitmap = image
        texture.updateURL(`data:binding:${identity}`, bitmap)
      }).catch(reject)
  })
  return { texture, ready }
}
