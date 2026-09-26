// Scene-owned engine resources, keyed by content and binding. Ontologies choose
// assets; this owner verifies and loads them, never interprets domain state.
import { Texture } from '@babylonjs/core/Materials/Textures/texture.js'

export function createRenderResources(scene, {
  fetchAsset = (url, options) => fetch(url, options),
  decode = (bytes, identity) => decodeTexture(scene, bytes, identity),
} = {}) {
  const assets = new Map()
  const bindings = new Map()
  let disposed = false

  function acquire(binding) {
    if (disposed) throw new Error('render resources are disposed')
    const { digest, slot, repeat } = binding
    const key = JSON.stringify([digest, slot, repeat])
    let entry = bindings.get(key)
    if (!entry) {
      let asset = assets.get(digest)
      if (!asset) {
        const controller = new AbortController()
        asset = { users: 0, controller, ready: verifiedBytes(digest, controller.signal, fetchAsset) }
        assets.set(digest, asset)
      }
      asset.users++
      entry = { users: 0, active: true, texture: null, asset, digest }
      entry.ready = asset.ready.then(async bytes => {
        if (!entry.active) return null
        const loading = decode(bytes, key)
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
    if (--entry.asset.users === 0) {
      entry.asset.controller.abort()
      assets.delete(entry.digest)
    }
  }

  return {
    acquire,
    dispose() {
      disposed = true
      for (const [key, entry] of bindings) retire(key, entry)
    },
  }
}

async function verifiedBytes(digest, signal, fetchAsset) {
  const response = await fetchAsset(`/assets/textures/${digest}.jpg`, { signal })
  if (!response.ok) throw new Error(`texture ${digest}: HTTP ${response.status}`)
  const bytes = await response.arrayBuffer()
  const hash = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))
  const actual = [...hash].map(n => n.toString(16).padStart(2, '0')).join('')
  if (actual !== digest) throw new Error(`texture ${digest}: content digest mismatch`)
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
