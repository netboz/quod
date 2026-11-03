// QVT1 carries the native collision surface's integer millimetre positions.
// This decoder creates renderer buffers only after measuring their allocation.
const COSTS = ['transfer bytes', 'geometry bytes', 'vertices', 'triangles']

function requireProfile(ok, message) {
  if (!ok) throw new Error(`Voxel profile: ${message}`)
}

export function decodeVoxel(input, palette, allowed, phase = [0, 0, 0]) {
  const bytes = input instanceof Uint8Array ? input : new Uint8Array(input)
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  requireProfile(bytes.length >= 16 && view.getUint32(0) === 0x51565431, 'invalid QVT1 header')
  const spacing = view.getUint32(4), triangles = view.getUint32(8), sharedVertices = view.getUint32(12)
  requireProfile(spacing >= 256 && spacing % 2 === 0 && spacing * 8 <= 0xffffffff,
    'invalid spacing')
  // Eight cubed MC33 cells, with at most twelve triangles in each cell.
  requireProfile(triangles <= 8 ** 3 * 12 && bytes.length === 16 + 38 * triangles,
    'invalid complete resource length')
  const vertices = triangles * 3
  const costs = [bytes.length, vertices * 36, vertices, triangles]
  requireProfile(Array.isArray(allowed) && allowed.length === costs.length &&
    allowed.every(n => n === Infinity || Number.isSafeInteger(n) && n >= 0), 'invalid allocation')
  costs.forEach((n, i) => requireProfile(n <= allowed[i], `${COSTS[i]} exceeded: ${n} > ${allowed[i]}`))
  requireProfile(palette instanceof Map, 'missing material palette')
  requireProfile(phase.length === 3 && phase.every(n => Number.isInteger(n) && n >= 0 && n < 1000000),
    'invalid canonical texture phase')

  const positions = new Float32Array(vertices * 3), normals = new Float32Array(vertices * 3)
  const uvs = new Float32Array(vertices * 2), indices = new Uint32Array(vertices)
  const distinct = new Set(), byMaterial = new Map()
  for (let t = 0; t < triangles; t++) {
    const offset = 16 + t * 38
    const points = Array.from({ length: 3 }, (_, corner) =>
      Array.from({ length: 3 }, (_, axis) => view.getUint32(offset + (corner * 3 + axis) * 4)))
    requireProfile(points.every(p => p.every(n => n <= spacing * 8)), 'vertex outside chunk')
    const material = view.getUint16(offset + 36)
    requireProfile(palette.has(material), `unknown material ${material}`)
    if (!byMaterial.has(material)) byMaterial.set(material, [])
    byMaterial.get(material).push(t * 3, t * 3 + 1, t * 3 + 2)
    const u = points[1].map((n, k) => BigInt(n - points[0][k]))
    const v = points[2].map((n, k) => BigInt(n - points[0][k]))
    const cross = u.map((_, k) => Number(u[(k + 1) % 3] * v[(k + 2) % 3] - u[(k + 2) % 3] * v[(k + 1) % 3]))
    const length = Math.hypot(...cross)
    requireProfile(length > 0, 'degenerate triangle')
    // Project onto the dominant face plane, including vertical/overhanging
    // walls. Oriented bases preserve the tangent-space normal-map convention.
    const axis = cross.reduce((best, n, k) => Math.abs(n) > Math.abs(cross[best]) ? k : best, 0)
    const sign = Math.sign(cross[axis])
    const rendered = points.map(p => p.map(n => Math.fround(n / 1000)))
    const a = rendered[1].map((n, k) => n - rendered[0][k])
    const b = rendered[2].map((n, k) => n - rendered[0][k])
    requireProfile(a.some((_, k) => a[(k + 1) % 3] * b[(k + 2) % 3] !== a[(k + 2) % 3] * b[(k + 1) % 3]),
      'triangle cannot be represented by renderer coordinates')
    points.forEach((p, corner) => {
      const index = t * 3 + corner
      distinct.add(p.join(','))
      positions.set(rendered[corner], index * 3)
      normals.set(cross.map(n => n / length), index * 3)
      const q = p.map((n, k) => (n + phase[k]) / 1000)
      const uv = axis === 0 ? [-sign * q[2], q[1]] : axis === 1 ? [q[0], -sign * q[2]] : [sign * q[0], q[1]]
      uvs.set(uv, index * 2)
    })
  }
  requireProfile(distinct.size === sharedVertices, 'incorrect shared vertex count')
  let start = 0
  const groups = [...byMaterial].sort((a, b) => a[0] - b[0]).map(([material, list]) => {
    indices.set(list, start)
    const group = { material, start, count: list.length }; start += list.length
    return group
  })
  return { spacing, costs, sharedVertices, positions, normals, uvs, indices, groups, palette,
    boundsMm: [0, 0, 0, spacing * 8, spacing * 8, spacing * 8] }
}
