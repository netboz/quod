#!/usr/bin/env node
// Offline asset authoring only. No world state, collider or runtime policy.
import assert from 'node:assert/strict'
import { mkdirSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { encodeAsset } from './asset-glb.mjs'
import { roofSeat } from './lobby-layout.mjs'

const shape = { feet: 6, radius: 5.5, oculusRadius: 1.4, height: 5.2,
  archHeight: 3.6, thickness: 0.08, angularSegments: 288, radialSegments: 32,
  seat: roofSeat }
const { feet, radius, oculusRadius, height, archHeight, thickness,
  angularSegments: N, radialSegments: M } = shape
const unit = v => { const length = Math.hypot(...v); return v.map(x => x / length) }
const cross = (a, b) => [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]
const subtract = (a, b) => a.map((x, i) => x - b[i])
const dot = (a, b) => a.reduce((sum, x, i) => sum + x*b[i], 0)
const top = { positions: [], normals: [], indices: [], material: 0 }
const bottom = { positions: [], normals: [], indices: [], material: 1 }

// One periodic sector function, evaluated around the full circle. The crown
// stays circular; scalloping grows smoothly towards the outer edge.
for (let i = 0; i <= M; i++) for (let j = 0; j < N; j++) {
  const t = i / M, angle = 2*Math.PI*j/N, r = oculusRadius + (radius-oculusRadius)*t
  const c = Math.cos(angle), s = Math.sin(angle)
  const scallop = (1 + Math.cos(feet*angle)) / 2
  const drop = archHeight * scallop**1.5
  const y = height - (height-archHeight)*t*t - drop*t**4
  const dr = (-2*(height-archHeight)*t - 4*drop*t**3) / (radius-oculusRadius)
  const da = archHeight*0.75*feet*Math.sqrt(scallop)*Math.sin(feet*angle)*t**4
  const normal = unit([-dr*c + da*s/r, 1, -dr*s - da*c/r])
  const point = [r*c, y, r*s]
  for (const [part, sign] of [[top, 1], [bottom, -1]]) {
    part.positions.push(...point.map((x, axis) => x + sign*thickness/2*normal[axis]))
    part.normals.push(...normal.map(x => sign*x))
  }
}
const minimumY = Math.min(...bottom.positions.filter((_, i) => i % 3 === 1))
// Fit the shell to the coping crown while keeping its existing overall height.
// Normals follow the same affine transform as the geometry.
const crown = Math.max(...top.positions.filter((_, i) => i % 3 === 1))-minimumY
const radialScale = roofSeat.radius/Math.hypot(...[bottom.positions[M*N*3],bottom.positions[M*N*3+2]])
const verticalScale = (crown-roofSeat.height)/crown
for (const part of [top, bottom]) {
  part.positions = part.positions.map((v, i) => Math.fround(i % 3 === 1
    ? roofSeat.height+(v-minimumY)*verticalScale : v*radialScale))
  for (let i=0;i<part.normals.length;i+=3) {
    const [x,y,z]=part.normals.slice(i,i+3)
    part.normals.splice(i,3,...unit([x/radialScale,y/verticalScale,z/radialScale]))
  }
}
for (let i = 0; i < M; i++) for (let j = 0; j < N; j++) {
  const a = i*N+j, b = (i+1)*N+j, c = (i+1)*N+(j+1)%N, d = i*N+(j+1)%N
  top.indices.push(a,c,b, a,d,c)
  bottom.indices.push(a,b,c, a,c,d)
}

// Close both boundaries of the annulus. Separate rim vertices retain a crisp
// material/normal boundary while their positions weld into one closed solid.
const rims = { positions: [], normals: [], indices: [], material: 0 }
for (const ring of [0, M]) {
  const base = rims.positions.length/3
  for (let j = 0; j < N; j++) for (const part of [top, bottom]) {
    rims.positions.push(...part.positions.slice((ring*N+j)*3, (ring*N+j+1)*3))
  }
  for (let j = 0; j < N; j++) {
    const a = base+2*j, b = a+1, d = base+2*((j+1)%N), c = d+1
    rims.indices.push(...(ring === 0 ? [a,b,c, a,c,d] : [a,c,b, a,d,c]))
  }
}
rims.normals = Array(rims.positions.length).fill(0)
for (let i = 0; i < rims.indices.length; i += 3) {
  const ids = rims.indices.slice(i,i+3), points = ids.map(id => rims.positions.slice(id*3,id*3+3))
  const n = cross(subtract(points[1],points[0]), subtract(points[2],points[0]))
  for (const id of ids) for (let axis = 0; axis < 3; axis++) rims.normals[id*3+axis] += n[axis]
}
for (let i = 0; i < rims.normals.length; i += 3) rims.normals.splice(i,3,...unit(rims.normals.slice(i,i+3)))
const parts = [top, bottom, rims]

// Verify the actual exported float positions: closed oriented manifold,
// connectedness, nondegenerate faces, sixfold symmetry and coplanar feet.
const vertices = new Map(), edges = new Map(), adjacency = new Map()
let volume = 0, minimumArea = Infinity
for (const part of parts) {
  const ids = []
  for (let i = 0; i < part.positions.length; i += 3) {
    const key = part.positions.slice(i,i+3).map(v => v.toFixed(6)).join(',')
    if (!vertices.has(key)) vertices.set(key, vertices.size)
    ids.push(vertices.get(key))
  }
  for (let i = 0; i < part.indices.length; i += 3) {
    const triangle = part.indices.slice(i,i+3), points = triangle.map(id => part.positions.slice(id*3,id*3+3))
    const normal = cross(subtract(points[1],points[0]),subtract(points[2],points[0]))
    minimumArea = Math.min(minimumArea, Math.hypot(...normal)/2)
    volume += dot(points[0],cross(points[1],points[2]))/6
    for (let edge = 0; edge < 3; edge++) {
      const a = ids[triangle[edge]], b = ids[triangle[(edge+1)%3]]
      const key = [Math.min(a,b),Math.max(a,b)].join(':')
      const entry = edges.get(key) ?? { count: 0, orientation: 0 }
      entry.count++; entry.orientation += a < b ? 1 : -1; edges.set(key,entry)
      if (!adjacency.has(a)) adjacency.set(a,new Set())
      adjacency.get(a).add(b)
    }
  }
}
assert(minimumArea > 1e-8, 'degenerate triangles')
assert(volume > 0, 'inverted shell')
assert([...edges.values()].every(e => e.count === 2 && e.orientation === 0), 'open or misoriented edge')
const reached = new Set(), queue = [0]
while (queue.length) {
  const id = queue.pop()
  if (reached.has(id)) continue
  reached.add(id); queue.push(...adjacency.get(id))
}
assert.equal(reached.size, vertices.size, 'disconnected shell')
let symmetryError = 0
const sector = 2*Math.PI/feet
for (const part of [top,bottom]) for (let i = 0; i <= M; i++) for (let j = 0; j < N; j++) {
  const a = (i*N+j)*3, b = (i*N+(j+N/feet)%N)*3
  const [x,y,z] = part.positions.slice(a,a+3)
  const rotated = [x*Math.cos(sector)-z*Math.sin(sector),y,x*Math.sin(sector)+z*Math.cos(sector)]
  symmetryError = Math.max(symmetryError, Math.hypot(...subtract(rotated,part.positions.slice(b,b+3))))
}
assert(symmetryError < 1e-6, 'sixfold symmetry drift')
const footTips = Array.from({length: feet},(_,k) => bottom.positions.slice((M*N+k*N/feet)*3,(M*N+k*N/feet)*3+3))
assert(footTips.every(p => Math.abs(p[1]-roofSeat.height) < 1e-7 &&
  Math.abs(Math.hypot(p[0],p[2])-roofSeat.radius) < 1e-6), 'feet miss border crown')
const checks = { connectedComponents: 1, closedManifold: true, minimumTriangleAreaM2: minimumArea,
  volumeM3: volume, maximumSymmetryErrorM: symmetryError, footTipsM: footTips }

const { glb, digest, costs, boundsMm } = encodeAsset('six-foot-roof', parts, [
  {name:'blue-grey shell',pbrMetallicRoughness:{baseColorFactor:[0.48,0.65,0.73,1],metallicFactor:0.15,roughnessFactor:0.46}},
  {name:'champagne underside',pbrMetallicRoughness:{baseColorFactor:[0.68,0.46,0.25,1],metallicFactor:0.25,roughnessFactor:0.5}},
], 'Quod procedural lobby roof')
const out = new URL('../../assets/lobby/',import.meta.url)
mkdirSync(out,{recursive:true})
writeFileSync(new URL('roof-six-feet.glb',out),glb)
const report = { schema:'quod-procedural-roof-v1', units:'metres', up:'Y', shape,
  output:{file:'roof-six-feet.glb',digest,profile:'gltf2-static-v1',costs,boundsMm,pivotMm:[0,0,0],front:'-z'},checks }
writeFileSync(new URL('roof-six-feet.json',out),JSON.stringify(report,null,2)+'\n')
console.log(JSON.stringify({file:fileURLToPath(new URL('roof-six-feet.glb',out)),...report},null,2))
