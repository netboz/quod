// The portable gltf2-static-v1 admission boundary. This module is also used by
// the offline publisher; Babylon only sees bytes that passed these checks.
const COSTS = ['transfer bytes', 'geometry bytes', 'vertices', 'triangles',
  'nodes', 'materials', 'image pixels']
const COMPONENT_BYTES = { 5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4 }
const COMPONENTS = { SCALAR: 1, VEC2: 2, VEC3: 3, VEC4: 4, MAT2: 4, MAT3: 9, MAT4: 16 }

function requireProfile(ok, message) {
  if (!ok) throw new Error(`GLB profile: ${message}`)
}
function index(array, n, what) {
  requireProfile(Number.isInteger(n) && n >= 0 && n < array.length, `invalid ${what} index`)
  return array[n]
}
function integer(n, what) {
  requireProfile(Number.isSafeInteger(n) && n >= 0, `invalid ${what}`)
  return n
}

export function validateGlb(input, allowed) {
  const bytes = input instanceof Uint8Array ? input : new Uint8Array(input)
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  requireProfile(bytes.length >= 20 && view.getUint32(0, true) === 0x46546c67 &&
    view.getUint32(4, true) === 2 && view.getUint32(8, true) === bytes.length,
  'invalid GLB header')
  let at = 12, json = null, bin = null
  while (at < bytes.length) {
    requireProfile(at + 8 <= bytes.length, 'truncated chunk header')
    const length = view.getUint32(at, true), type = view.getUint32(at + 4, true)
    at += 8
    requireProfile(length % 4 === 0 && at + length <= bytes.length, 'invalid chunk length')
    if (type === 0x4e4f534a && json === null && bin === null) {
      json = bytes.subarray(at, at + length)
    } else if (type === 0x004e4942 && json && bin === null) {
      bin = bytes.subarray(at, at + length)
    } else requireProfile(false, 'unexpected GLB chunk')
    at += length
  }
  requireProfile(json && bin, 'JSON and BIN chunks are required')
  let doc
  try { doc = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(json)) }
  catch { throw new Error('GLB profile: invalid JSON chunk') }
  requireProfile(doc.asset?.version === '2.0' && !doc.asset.minVersion,
    'unsupported glTF version')
  requireProfile(!doc.extensionsUsed?.length && !doc.extensionsRequired?.length,
    'extensions are not listed in this profile')
  requireProfile(!doc.extensions && !doc.animations && !doc.skins && !doc.cameras,
    'unsupported scene feature')
  requireProfile(Array.isArray(doc.scenes) && doc.scenes.length === 1 && doc.scene === 0,
    'one selected scene is required')
  requireProfile(Array.isArray(doc.buffers) && doc.buffers.length === 1 &&
    doc.buffers[0].uri === undefined &&
    integer(doc.buffers[0].byteLength, 'buffer length') <= bin.length &&
    bin.length - doc.buffers[0].byteLength < 4, 'external or invalid buffer')
  const views = doc.bufferViews ?? [], accessors = doc.accessors ?? []
  const nodes = doc.nodes ?? [], meshes = doc.meshes ?? [], materials = doc.materials ?? []
  const images = doc.images ?? [], textures = doc.textures ?? [], samplers = doc.samplers ?? []
  const usedViews = new Set()
  function noExtensions(value) {
    if (!value || typeof value !== 'object') return
    requireProfile(!value.extensions, 'extensions are not listed in this profile')
    for (const child of Object.values(value)) noExtensions(child)
  }
  noExtensions(doc)
  for (const part of views) {
    const start = integer(part.byteOffset ?? 0, 'buffer view offset')
    const length = integer(part.byteLength, 'buffer view length')
    requireProfile(part.buffer === 0 && start + length <= doc.buffers[0].byteLength &&
      part.byteStride === undefined, 'invalid or interleaved buffer view')
  }
  for (const accessor of accessors) {
    requireProfile(accessor.bufferView !== undefined && !accessor.sparse,
      'sparse or unbound accessor')
    const part = index(views, accessor.bufferView, 'accessor buffer view')
    const stride = COMPONENT_BYTES[accessor.componentType] * COMPONENTS[accessor.type]
    const count = integer(accessor.count, 'accessor count')
    const offset = integer(accessor.byteOffset ?? 0, 'accessor offset')
    requireProfile(stride > 0 &&
      ((part.byteOffset ?? 0) + offset) % COMPONENT_BYTES[accessor.componentType] === 0 &&
      offset + stride * count <= part.byteLength, 'invalid accessor range')
  }
  for (const sampler of samplers) {
    requireProfile([undefined, 33071, 33648, 10497].includes(sampler.wrapS) &&
      [undefined, 33071, 33648, 10497].includes(sampler.wrapT), 'unsupported sampler')
  }
  for (const texture of textures) {
    index(images, texture.source, 'texture source')
    if (texture.sampler !== undefined) index(samplers, texture.sampler, 'texture sampler')
    requireProfile(!texture.extensions, 'texture extension')
  }
  for (const material of materials) {
    requireProfile(!material.extensions, 'material extension')
    for (const slot of [material.pbrMetallicRoughness?.baseColorTexture,
      material.pbrMetallicRoughness?.metallicRoughnessTexture,
      material.normalTexture, material.occlusionTexture, material.emissiveTexture]) {
      if (slot) {
        index(textures, slot.index, 'material texture')
        requireProfile(slot.texCoord === undefined || slot.texCoord === 0,
          'only UV0 is supported')
      }
    }
  }
  let pixels = 0
  for (const image of images) {
    requireProfile(image.uri === undefined &&
      ['image/png', 'image/jpeg'].includes(image.mimeType),
    'external or unsupported image')
    const part = index(views, image.bufferView, 'image buffer view')
    const data = bin.subarray(part.byteOffset ?? 0, (part.byteOffset ?? 0) + part.byteLength)
    pixels += imagePixels(data, image.mimeType)
    requireProfile(Number.isSafeInteger(pixels), 'image pixel total overflow')
  }
  const binView = new DataView(bin.buffer, bin.byteOffset, bin.byteLength)
  const positions = new Map(), checkedIndices = new Set()
  const meshStats = meshes.map(mesh => {
    requireProfile(Array.isArray(mesh.primitives) && mesh.primitives.length > 0 &&
      !mesh.weights && !mesh.extensions, 'unsupported mesh feature')
    const low = [Infinity, Infinity, Infinity], high = [-Infinity, -Infinity, -Infinity]
    let vertices = 0, triangles = 0
    for (const primitive of mesh.primitives) {
      requireProfile((primitive.mode ?? 4) === 4 && !primitive.targets &&
        !primitive.extensions, 'only static triangles are supported')
      const attrs = primitive.attributes
      requireProfile(attrs && attrs.POSITION !== undefined &&
        Object.keys(attrs).every(k => ['POSITION', 'NORMAL', 'TANGENT', 'TEXCOORD_0', 'COLOR_0'].includes(k)),
      'unsupported vertex attributes')
      const position = index(accessors, attrs.POSITION, 'position accessor')
      requireProfile(position.type === 'VEC3' && position.componentType === 5126 &&
        position.count > 0,
        'positions must be float VEC3')
      let bounds = positions.get(attrs.POSITION)
      if (!bounds) {
        const part = views[position.bufferView]
        const offset = (part.byteOffset ?? 0) + (position.byteOffset ?? 0)
        const min = [Infinity, Infinity, Infinity], max = [-Infinity, -Infinity, -Infinity]
        for (let i = 0; i < position.count; i++) for (let axis = 0; axis < 3; axis++) {
          const value = binView.getFloat32(offset + i * 12 + axis * 4, true)
          requireProfile(Number.isFinite(value), 'non-finite vertex position')
          min[axis] = Math.min(min[axis], value)
          max[axis] = Math.max(max[axis], value)
        }
        for (const [field, actual] of [['min', min], ['max', max]])
          requireProfile(Array.isArray(position[field]) && position[field].length === 3 &&
            position[field].every((value, axis) =>
              Number.isFinite(value) && Math.fround(value) === actual[axis]),
          `position ${field} differs from vertex data`)
        bounds = { min, max }
        positions.set(attrs.POSITION, bounds)
      }
      for (let axis = 0; axis < 3; axis++) {
        low[axis] = Math.min(low[axis], bounds.min[axis])
        high[axis] = Math.max(high[axis], bounds.max[axis])
      }
      for (const [kind, accessorIndex] of Object.entries(attrs)) {
        const accessor = index(accessors, accessorIndex, 'vertex accessor')
        requireProfile(accessor.count === position.count, 'attribute count mismatch')
        requireProfile(validAttribute(kind, accessor), `invalid ${kind} accessor`)
        usedViews.add(accessor.bufferView)
      }
      let count = position.count
      if (primitive.indices !== undefined) {
        const indices = index(accessors, primitive.indices, 'index accessor')
        requireProfile(indices.type === 'SCALAR' && !indices.normalized &&
          [5121, 5123, 5125].includes(indices.componentType),
          'invalid triangle indices')
        const indexView = views[indices.bufferView]
        const indexOffset = (indexView.byteOffset ?? 0) + (indices.byteOffset ?? 0)
        const width = COMPONENT_BYTES[indices.componentType]
        const checkKey = `${primitive.indices}:${position.count}`
        if (!checkedIndices.has(checkKey)) {
          for (let i = 0; i < indices.count; i++) {
            const at = indexOffset + i * width
            const vertex = width === 1 ? binView.getUint8(at)
              : width === 2 ? binView.getUint16(at, true) : binView.getUint32(at, true)
            requireProfile(vertex < position.count, 'triangle index exceeds vertex count')
          }
          checkedIndices.add(checkKey)
        }
        usedViews.add(indices.bufferView)
        count = indices.count
      }
      requireProfile(count % 3 === 0, 'incomplete triangles')
      if (primitive.material !== undefined) index(materials, primitive.material, 'material')
      vertices += position.count; triangles += count / 3
    }
    return { vertices, triangles, low, high }
  })
  const seen = new Set(), active = new Set(), usedMeshes = new Set()
  const min = [Infinity, Infinity, Infinity], max = [-Infinity, -Infinity, -Infinity]
  let vertices = 0, triangles = 0
  const identity = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
  function visit(n, parent) {
    requireProfile(!active.has(n) && !seen.has(n), 'cyclic or reused scene node')
    const node = index(nodes, n, 'scene node')
    active.add(n); seen.add(n)
    requireProfile(node.camera === undefined && node.skin === undefined &&
      !node.weights && !node.extensions, 'unsupported node feature')
    for (const [field, width] of [['matrix', 16], ['translation', 3],
      ['rotation', 4], ['scale', 3]]) {
      if (node[field] !== undefined) requireProfile(Array.isArray(node[field]) &&
        node[field].length === width && node[field].every(Number.isFinite),
      `invalid node ${field}`)
    }
    requireProfile(node.matrix === undefined ||
      (node.translation === undefined && node.rotation === undefined && node.scale === undefined),
    'matrix and TRS cannot coexist')
    if (node.matrix) requireProfile(node.matrix[3] === 0 && node.matrix[7] === 0 &&
      node.matrix[11] === 0 && node.matrix[15] === 1, 'non-affine node matrix')
    if (node.rotation) requireProfile(
      Math.abs(node.rotation.reduce((sum, value) => sum + value * value, 0) - 1) < 0.001,
      'node rotation must be a unit quaternion')
    const matrix = multiply(parent, localMatrix(node))
    if (node.mesh !== undefined) {
      const stat = index(meshStats, node.mesh, 'node mesh')
      usedMeshes.add(node.mesh)
      vertices += stat.vertices; triangles += stat.triangles
      for (const x of [stat.low[0], stat.high[0]])
        for (const y of [stat.low[1], stat.high[1]])
          for (const z of [stat.low[2], stat.high[2]])
            for (let axis = 0; axis < 3; axis++) {
              const value = matrix[axis] * x + matrix[axis + 4] * y +
                matrix[axis + 8] * z + matrix[axis + 12]
              requireProfile(Number.isFinite(value), 'non-finite node bounds')
              min[axis] = Math.min(min[axis], value)
              max[axis] = Math.max(max[axis], value)
            }
    }
    for (const c of node.children ?? []) visit(c, matrix)
    active.delete(n)
  }
  for (const root of doc.scenes[0].nodes ?? []) visit(root, identity)
  requireProfile(seen.size === nodes.length && usedMeshes.size === meshes.length &&
    min.every(Number.isFinite), 'unselected or empty scene content')
  const geometryBytes = [...usedViews].reduce((sum, n) => sum + views[n].byteLength, 0)
  const costs = [bytes.length, geometryBytes, vertices, triangles, nodes.length,
    materials.length, pixels]
  requireProfile(costs.every(Number.isSafeInteger), 'resource count overflow')
  if (allowed) checkGlbCosts(costs, allowed)
  const boundsMm = [...min, ...max].map((n, i) => i < 3 ?
    Math.floor(snapMm(n)) : Math.ceil(snapMm(n)))
  const paddedAxes = []
  for (let axis = 0; axis < 3; axis++) if (boundsMm[axis] === boundsMm[axis + 3]) {
    boundsMm[axis]--; boundsMm[axis + 3]++
    paddedAxes.push(['X', 'Y', 'Z'][axis])
  }
  requireProfile(boundsMm.every(Number.isSafeInteger), 'invalid scene bounds')
  return { costs, boundsMm, paddedAxes, document: doc }
}

export function checkGlbCosts(costs, allowed) {
  requireProfile(Array.isArray(allowed) && allowed.length === COSTS.length &&
    allowed.every(n => Number.isSafeInteger(n) && n > 0), 'invalid resource allowance')
  costs.forEach((cost, i) => requireProfile(cost <= allowed[i],
    `${COSTS[i]} exceeded: ${cost} > ${allowed[i]}`))
}

function validAttribute(kind, accessor) {
  const { type, componentType, normalized } = accessor
  if (kind === 'POSITION') return type === 'VEC3' && componentType === 5126 &&
    !normalized
  const vector = kind === 'TANGENT' ? type === 'VEC4'
    : kind === 'TEXCOORD_0' ? type === 'VEC2'
      : kind === 'COLOR_0' ? ['VEC3', 'VEC4'].includes(type) : type === 'VEC3'
  if (!vector) return false
  if (componentType === 5126) return !normalized
  if (kind === 'NORMAL' || kind === 'TANGENT')
    return [5120, 5122].includes(componentType) && normalized === true
  return [5121, 5123].includes(componentType) && normalized === true
}

function snapMm(metres) {
  const millimetres = metres * 1000
  const nearest = Math.round(millimetres)
  const ulp = metres === 0 ? 0 : 2 ** (Math.floor(Math.log2(Math.abs(metres))) - 23)
  const tolerance = Math.min(0.25, Math.max(0.0001, 4 * ulp * 1000))
  return Math.abs(millimetres - nearest) <= tolerance ? nearest : millimetres
}

function multiply(a, b) {
  const result = Array(16).fill(0)
  for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++)
    for (let k = 0; k < 4; k++) result[c * 4 + r] += a[k * 4 + r] * b[c * 4 + k]
  return result
}

function localMatrix(node) {
  if (node.matrix) return node.matrix
  const [x, y, z, w] = node.rotation ?? [0, 0, 0, 1]
  const [sx, sy, sz] = node.scale ?? [1, 1, 1]
  const [tx, ty, tz] = node.translation ?? [0, 0, 0]
  return [(1 - 2 * (y * y + z * z)) * sx, 2 * (x * y + z * w) * sx,
    2 * (x * z - y * w) * sx, 0,
    2 * (x * y - z * w) * sy, (1 - 2 * (x * x + z * z)) * sy,
    2 * (y * z + x * w) * sy, 0,
    2 * (x * z + y * w) * sz, 2 * (y * z - x * w) * sz,
    (1 - 2 * (x * x + y * y)) * sz, 0, tx, ty, tz, 1]
}

function imagePixels(data, mime) {
  if (mime === 'image/png') {
    const v = new DataView(data.buffer, data.byteOffset, data.byteLength)
    requireProfile(data.length >= 24 && v.getUint32(0) === 0x89504e47 &&
      v.getUint32(4) === 0x0d0a1a0a && v.getUint32(12) === 0x49484452,
    'invalid PNG')
    const width = v.getUint32(16), height = v.getUint32(20)
    requireProfile(width > 0 && height > 0, 'invalid PNG dimensions')
    return width * height
  }
  requireProfile(data.length >= 4 && data[0] === 0xff && data[1] === 0xd8,
    'invalid JPEG')
  let at = 2
  while (at + 4 <= data.length) {
    requireProfile(data[at++] === 0xff, 'invalid JPEG segment')
    let marker = data[at++]
    while (marker === 0xff) marker = data[at++]
    const length = (data[at] << 8) | data[at + 1]
    requireProfile(length >= 2 && at + length <= data.length, 'invalid JPEG segment length')
    if ([0xc0, 0xc1, 0xc2, 0xc3].includes(marker)) {
      requireProfile(length >= 7, 'invalid JPEG frame')
      const height = (data[at + 3] << 8) | data[at + 4]
      const width = (data[at + 5] << 8) | data[at + 6]
      requireProfile(width > 0 && height > 0, 'invalid JPEG dimensions')
      return width * height
    }
    at += length
  }
  throw new Error('GLB profile: JPEG dimensions missing')
}
