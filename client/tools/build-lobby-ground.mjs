#!/usr/bin/env node
// Offline annular ground asset with rounded borders and a curved glass cover.
import assert from 'node:assert/strict'
import { readFileSync, writeFileSync } from 'node:fs'
import { encodeAsset } from './asset-glb.mjs'
import { roofSeat } from './lobby-layout.mjs'

const shape = { radius: roofSeat.radius+0.25, openingRadius: 2.2, innerBorderHeight: 0.20,
  outerBorderHeight: roofSeat.height, borderCrownRadius: roofSeat.radius,
  underside: -0.45, segments: 288, curveSegments: 8,
  glass: { edge: -0.1, depth: 0.45, thickness: 0.02, rings: 16 } }
const { segments: N, curveSegments: M } = shape
const R = roofSeat.radius
const parts = Array.from({length: 2}, (_, material) => ({positions:[], normals:[], indices:[], material}))
// Closed radial section: inner wall, softly rolled coping, level walkway,
// rounded outer border and underside. The glass seats in its central opening.
const curves = [
  [[2.2,-0.30],[2.2,-0.10],[2.2,0.20],[2.45,0.20]],
  [[2.45,0.20],[2.72,0.20],[2.72,0],[3.0,0]],
  [[3.0,0],[4.7,0],[R-1.0,0],[R-0.4,0]],
  [[R-0.4,0],[R-0.17,0],[R-0.19,0.45],[R-0.19,0.78]],
  [[R-0.19,0.78],[R-0.19,0.92],[R-0.15,1.0],[R,roofSeat.height]],
  [[R,roofSeat.height],[R+0.17,1.0],[R+0.25,0.92],[R+0.25,0.78]],
  [[R+0.25,0.78],[R+0.25,0.45],[R+0.25,0.10],[R+0.25,-0.18]],
  [[R+0.25,-0.18],[R+0.25,-0.36],[R+0.15,-0.45],[R-0.05,-0.45]],
  [[R-0.05,-0.45],[R-1.0,-0.45],[4.0,-0.45],[2.4,-0.45]],
  [[2.4,-0.45],[2.28,-0.45],[2.2,-0.42],[2.2,-0.30]],
]
const profile = curves.flatMap(([a,b,c,d], segment) => Array.from({length:M},(_,i) => {
  const t=i/M, u=1-t
  const p=a.map((x,k) => u*u*u*x+3*u*u*t*b[k]+3*u*t*t*c[k]+t*t*t*d[k])
  const tangent=a.map((x,k) => 3*u*u*(b[k]-x)+6*u*t*(c[k]-b[k])+3*t*t*(d[k]-c[k]))
  const material = segment <= 4 || segment === curves.length-1 ? 1 : 0
  return {r:p[0],y:p[1],normal:[-tangent[1],tangent[0]],material}
}))
function vertex(p,j) {
  const angle=2*Math.PI*j/N, c=Math.cos(angle), s=Math.sin(angle)
  const [nr,ny]=p.normal, length=Math.hypot(nr,ny)
  return {position:[p.r*c,p.y,p.r*s].map(Math.fround),normal:[nr*c/length,ny/length,nr*s/length]}
}
for (let i=0; i<profile.length; i++) {
  const p=profile[i], q=profile[(i+1)%profile.length], part=parts[p.material]
  const offset=part.positions.length/3
  for (let j=0;j<N;j++) for (const sample of [p,q]) {
    const v=vertex(sample,j)
    part.positions.push(...v.position); part.normals.push(...v.normal)
  }
  for (let j=0;j<N;j++) {
    const a=offset+2*j, b=a+1, d=offset+2*((j+1)%N), c=d+1
    part.indices.push(a,c,b,a,d,c)
  }
}

// A closed glass bowl seats inside the existing rolled opening. Core glTF
// alpha blending keeps it within the ordinary static asset profile.
const glass = {positions:[],normals:[],indices:[],material:2}
const {edge,depth,thickness,rings} = shape.glass
for (const side of [1,-1]) {
  const centre = glass.positions.length/3
  glass.positions.push(0,edge-depth-(side<0?thickness:0),0)
  glass.normals.push(0,side,0)
  for (let row=1;row<=rings;row++) for (let j=0;j<N;j++) {
    const r=shape.openingRadius*row/rings,angle=2*Math.PI*j/N,c=Math.cos(angle),s=Math.sin(angle)
    const gradient=2*depth*r/shape.openingRadius**2,length=Math.hypot(gradient,1)
    glass.positions.push(r*c,edge-depth*(1-(r/shape.openingRadius)**2)-(side<0?thickness:0),r*s)
    glass.normals.push(-side*gradient*c/length,side/length,-side*gradient*s/length)
  }
  const triangle=(a,b,c)=>glass.indices.push(a,...(side>0?[b,c]:[c,b]))
  for (let j=0;j<N;j++) {
    const next=(j+1)%N
    triangle(centre,centre+1+next,centre+1+j)
    for (let row=1;row<rings;row++) {
      const a=centre+1+(row-1)*N+j,b=a+N,c=centre+1+row*N+next,d=c-N
      triangle(a,c,b);triangle(a,d,c)
    }
  }
}
const bottom=1+rings*N,outer=1+(rings-1)*N
for (let j=0;j<N;j++) {
  const a=outer+j,b=outer+(j+1)%N
  glass.indices.push(a,b,b+bottom,a,b+bottom,a+bottom)
}
parts.push(glass)

// Verify exported positions, winding and all welded edges before admission.
const edges = new Map()
let volume = 0, minimumArea = Infinity
for (const part of parts) for (let i = 0; i < part.indices.length; i += 3) {
  const p = part.indices.slice(i,i+3).map(k => part.positions.slice(k*3,k*3+3))
  const [a,b,c] = p, u = b.map((x,k) => x-a[k]), v = c.map((x,k) => x-a[k])
  const cross = [u[1]*v[2]-u[2]*v[1],u[2]*v[0]-u[0]*v[2],u[0]*v[1]-u[1]*v[0]]
  minimumArea = Math.min(minimumArea,Math.hypot(...cross)/2)
  volume += a.reduce((sum,x,k) => sum+x*cross[k],0)/6
  const keys = p.map(v => v.map(x => Number(x.toFixed(6))).join(','))
  for (let k = 0; k < 3; k++) {
    const a = keys[k], b = keys[(k+1)%3], key = [a,b].sort().join(':')
    const edge = edges.get(key) ?? {count:0,orientation:0}
    edge.count++; edge.orientation += a < b ? 1 : -1; edges.set(key,edge)
  }
}
assert(minimumArea > 1e-8 && volume > 0, 'degenerate or inverted ground')
assert([...edges.values()].every(e => e.count === 2 && e.orientation === 0), 'open or misoriented ground')
const roof = JSON.parse(readFileSync(new URL('../../assets/lobby/roof-six-feet.json',import.meta.url)))
const crown = profile.find(p => p.r === roofSeat.radius && p.y === roofSeat.height)
assert(crown,'ground has no border crown at roof seating datum')
const contactErrors = roof.checks.footTipsM.map((foot,k) => {
  const contact = vertex(crown,k*N/roof.shape.feet).position
  return Math.hypot(...foot.map((v,i) => v-contact[i]))
})
const contactError = Math.max(...contactErrors)
assert(contactError < 1e-6,'roof feet do not meet actual border vertices')
const { glb, digest, costs, boundsMm } = encodeAsset('lobby-ground',parts,[
  {name:'blue-grey porcelain',pbrMetallicRoughness:{baseColorFactor:[0.48,0.65,0.73,1],metallicFactor:0,roughnessFactor:0.72}},
  {name:'champagne interior',pbrMetallicRoughness:{baseColorFactor:[0.68,0.46,0.25,1],metallicFactor:0,roughnessFactor:0.72}},
  {name:'curved glass porthole',alphaMode:'BLEND',doubleSided:true,
    pbrMetallicRoughness:{baseColorFactor:[0.32,0.72,0.82,0.32],metallicFactor:0.12,roughnessFactor:0.08}},
])
const report = {schema:'quod-procedural-ground-v4',units:'metres',up:'Y',shape,
  output:{file:'ground.glb',digest,profile:'gltf2-static-v1',costs,boundsMm,pivotMm:[0,0,0],front:'-z'},
  checks:{closedManifold:true,minimumTriangleAreaM2:minimumArea,volumeM3:volume,
    roofContactErrorM:contactError,walkwayY:0,glassDiameterM:2*shape.openingRadius}}
const out = new URL('../../assets/lobby/',import.meta.url)
writeFileSync(new URL('ground.glb',out),glb)
writeFileSync(new URL('ground.json',out),JSON.stringify(report,null,2)+'\n')
console.log(JSON.stringify(report,null,2))
