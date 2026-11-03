// Scene-owned engine resources, keyed by content and binding. Ontologies choose
// assets; this owner verifies and loads them, never interprets domain state.
import { Texture } from '@babylonjs/core/Materials/Textures/texture.js'
import { validateGlb, checkGlbCosts } from './glb-profile.js'
import { decodeVoxel } from './voxel-profile.js'
import { AssetContainer } from '@babylonjs/core/assetContainer.js'
import { Mesh } from '@babylonjs/core/Meshes/mesh.js'
import { VertexData } from '@babylonjs/core/Meshes/mesh.vertexData.js'
import { PBRMaterial } from '@babylonjs/core/Materials/PBR/pbrMaterial.js'
import { Material } from '@babylonjs/core/Materials/material.js'
import { MultiMaterial } from '@babylonjs/core/Materials/multiMaterial.js'
import { SubMesh } from '@babylonjs/core/Meshes/subMesh.js'
import { Color3 } from '@babylonjs/core/Maths/math.color.js'

export function createRenderResources(scene, {
  fetchAsset = (url, options) => fetch(url, options),
  decode = (bytes, identity) => decodeTexture(scene, bytes, identity),
  decodeModel = async bytes => {
    // GLTF2 may instance a mesh shared by several nodes, without an extension.
    await import('@babylonjs/core/Meshes/instancedMesh.js')
    await import('@babylonjs/loaders/glTF/2.0/glTFLoader.js')
    const { LoadAssetContainerAsync } = await import('@babylonjs/core/Loading/sceneLoader.js')
    return LoadAssetContainerAsync(new Uint8Array(bytes), scene,
      { pluginExtension: '.glb', name: 'verified.glb' })
  },
  decodeTerrain,
} = {}) {
  const assets = new Map()
  const bindings = new Map()
  const models = new Map()
  const images = new Map()
  let disposed = false
  decodeTerrain ??= data => terrainContainer(scene, data, { acquire })

  function acquireBytes(kind, digest, maximum = Infinity, supplied) {
    const key = `${kind}:${digest}`
    let asset = assets.get(key)
    if (!asset) {
      const controller = new AbortController()
      asset = { users: 0, controller, maximum,
        ready: (kind === 'voxel'
          ? verifiedSuppliedBytes(supplied, digest, maximum)
          : verifiedBytes(kind, digest, controller.signal, fetchAsset, () => asset.maximum)).catch(error => {
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

  // DOM and spatial GUI consumers share verified bytes with scene textures.
  function acquireImage(digest) {
    if (disposed) throw new Error('render resources are disposed')
    let entry = images.get(digest)
    if (!entry) {
      const bytes = acquireBytes('texture', digest)
      entry = { users: 0, active: true, url: null, bytes }
      entry.ready = bytes.asset.ready.then(data => {
        if (!entry.active) return null
        entry.url = URL.createObjectURL(new Blob([data], { type: 'image/jpeg' }))
        return entry.url
      })
      images.set(digest, entry)
    }
    entry.users++
    let released = false
    return { ready: entry.ready, release() {
      if (released) return
      released = true
      if (--entry.users === 0) retireImage(digest, entry)
    } }
  }

  function retireImage(digest, entry) {
    if (!entry.active) return
    entry.active = false
    images.delete(digest)
    if (entry.url) URL.revokeObjectURL(entry.url)
    entry.bytes.release()
  }

  function retire(key, entry) {
    if (!entry.active) return
    entry.active = false
    bindings.delete(key)
    entry.texture?.dispose()
    entry.bytes.release()
  }

  function acquireModel({ digest, profile, allowed, bounds, payload, palette, originMm }) {
    if (disposed) throw new Error('render resources are disposed')
    const terrain = profile === 'qvt1'
    if (!terrain && profile !== 'gltf2-static-v1') throw new Error('unsupported mesh profile')
    if (terrain && (!(payload instanceof Uint8Array) || !(palette instanceof Map))) {
      throw new Error('terrain requires authorized bytes and a material palette')
    }
    const surfaces = terrain ? new Map([...palette].sort((a, b) => a[0] - b[0])
      .map(([id, surface]) => [id, structuredClone(surface)])) : null
    // Every authored repeat is an integer number of thousandths. Reducing the
    // canonical origin modulo 1000 m preserves all texture phases, even far
    // beyond Number's integer range, and never moves during a local rebase.
    const phase = terrain ? (originMm ?? [0n, 0n, 0n]).map(n => Number((BigInt(n) % 1000000n + 1000000n) % 1000000n)) : null
    const key = `${profile}:${digest}:${terrain ? JSON.stringify([[...surfaces], phase]) : ''}`
    let entry = models.get(key)
    if (!entry) {
      const bytes = acquireBytes(terrain ? 'voxel' : 'model', digest, allowed[0], payload)
      entry = { users: new Set(), active: true, container: null, bytes }
      entry.ready = bytes.asset.ready.then(async data => {
        if (!entry.active) return null
        // Allocation is checked before generating terrain vertex buffers.
        const allocation = terrain ? allowed.map((_, i) => Math.max(...[...entry.users].map(user => user.allowed[i]))) : null
        const decoded = terrain ? decodeVoxel(data, surfaces, allocation, phase) : validateGlb(data)
        const { costs, boundsMm } = decoded
        entry.costs = costs
        entry.boundsMm = boundsMm
        // No template is decoded unless at least one current, authorized
        // occurrence can afford the measured asset.
        if (![...entry.users].some(user => permits(costs, user.allowed) &&
          sameBounds(boundsMm, user.bounds))) {
          const first = [...entry.users][0]
          checkCosts(costs, first.allowed)
          checkBounds(boundsMm, first.bounds)
        }
        let container
        if (terrain) {
          const loading = decodeTerrain(decoded)
          container = loading.container
          entry.container = container
          await loading.ready
        } else container = await decodeModel(data)
        if (!entry.active) { container.dispose(); return null }
        entry.container = container
        return container
      }).catch(error => {
        entry.container?.dispose(); entry.container = null
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
        checkCosts(entry.costs, allowed)
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

  function checkCosts(costs, allowed) {
    if (costs.length === 7) checkGlbCosts(costs, allowed)
    else if (!permits(costs, allowed)) throw new Error('terrain geometry allocation exceeded')
  }

  return {
    acquire,
    acquireModel,
    acquireImage,
    dispose() {
      disposed = true
      for (const [key, entry] of bindings) retire(key, entry)
      for (const [key, entry] of models) retireModel(key, entry)
      for (const [key, entry] of images) retireImage(key, entry)
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
    throw new Error(`asset-local bounds differ from verified geometry: ${actual.join(',')}`)
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
  return verifyDigest(bytes, digest, kind)
}

async function verifiedSuppliedBytes(input, digest, maximum) {
  if (!(input instanceof Uint8Array) || input.byteLength > maximum) throw new Error('terrain transfer bytes exceeded')
  return verifyDigest(Uint8Array.from(input), digest, 'voxel')
}

async function verifyDigest(bytes, digest, kind) {
  const hash = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))
  const actual = [...hash].map(n => n.toString(16).padStart(2, '0')).join('')
  if (actual !== digest) throw new Error(`${kind} ${digest}: content digest mismatch`)
  return bytes
}

function terrainContainer(scene, data, resources) {
  const container = new AssetContainer(scene)
  if (!data.indices.length) return { container, ready: Promise.resolve() }
  try {
    const mesh = new Mesh('verified-terrain', scene)
    // QVT1 uses outward right-handed winding, independent of Babylon's
    // procedural-mesh default winding for the scene's handedness.
    mesh.sideOrientation = Material.CounterClockWiseSideOrientation
    container.meshes.push(mesh)
    const vertices = new VertexData()
    vertices.positions = data.positions; vertices.normals = data.normals
    vertices.uvs = data.uvs; vertices.indices = data.indices
    vertices.applyToMesh(mesh)
    const material = new MultiMaterial('terrain-surfaces', scene)
    container.multiMaterials.push(material)
    mesh.material = material
    mesh.releaseSubMeshes()
    const pending = data.groups.map((group, index) => {
      const surface = createSurface(scene, `terrain:${group.material}`, data.palette.get(group.material), resources)
      container.materials.push(surface.material)
      material.subMaterials.push(surface.material)
      new SubMesh(index, 0, data.positions.length / 3, group.start, group.count, mesh)
      return surface.ready
    })
    container.populateRootNodes(); container.removeAllFromScene()
    return { container, ready: Promise.all(pending) }
  } catch (error) { container.dispose(); throw error }
}

// One neutral surface binding for ordinary marks and generated terrain.
// Disposing its material releases texture leases, including pending decodes.
export function createSurface(scene, name, definition, resources, sky = false) {
  const material = new PBRMaterial(name, scene), leases = []
  let active = true
  material.onDisposeObservable.addOnce(() => {
    active = false
    for (const lease of leases) lease.release()
  })
  try {
    material.albedoColor = Color3.FromHexString(definition.colour).toLinearSpace()
    material.metallic = definition.metallic; material.roughness = definition.roughness
    if (sky) material.albedoColor.scaleInPlace(definition.emission)
    else material.emissiveColor = material.albedoColor.scale(definition.emission)
    material.unlit = sky; material.backFaceCulling = !sky; material.disableDepthWrite = sky
    material.invertNormalMapX = !scene.useRightHandedSystem
    material.invertNormalMapY = scene.useRightHandedSystem
    material.useRoughnessFromMetallicTextureAlpha = false
    material.useRoughnessFromMetallicTextureGreen = true
    material.useMetallnessFromMetallicTextureBlue = true
    material.useAmbientOcclusionFromMetallicTextureRed = true
    for (const binding of definition.textures) {
      if (!resources) throw new Error('textured surfaces require a render resource owner')
      leases.push(resources.acquire(binding))
    }
    const ready = Promise.all(leases.map(lease => lease.ready)).then(textures => {
      if (!active) return null
      const slots = { base_colour: 'albedoTexture', normal: 'bumpTexture', orm: 'metallicTexture' }
      textures.forEach((texture, i) => {
        const slot = definition.textures[i].slot
        material[slots[slot]] = texture
      })
      return material
    })
    return { material, ready }
  } catch (error) { material.dispose(); throw error }
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
