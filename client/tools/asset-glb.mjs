// Offline static asset encoding; admission stays with the existing GLB profile.
import { createHash } from 'node:crypto'
import { validateGlb } from '../src/glb-profile.js'

export function encodeAsset(name, parts, materials, generator = 'Quod procedural lobby asset') {
  const chunks = [], bufferViews = [], accessors = []
  let offset = 0
  function accessor(values, type, componentType, bounds = false) {
    const data = Buffer.alloc(values.length*4)
    values.forEach((v,i) => componentType === 5126 ? data.writeFloatLE(v,i*4) : data.writeUInt32LE(v,i*4))
    const view = bufferViews.length
    bufferViews.push({buffer:0,byteOffset:offset,byteLength:data.length}); chunks.push(data); offset += data.length
    const row = {bufferView:view,componentType,count:values.length/(type === 'VEC3' ? 3 : 1),type}
    if (bounds) {
      row.min = [0,1,2].map(axis => Math.min(...values.filter((_,i) => i%3 === axis)))
      row.max = [0,1,2].map(axis => Math.max(...values.filter((_,i) => i%3 === axis)))
    }
    accessors.push(row); return accessors.length-1
  }
  const primitives = parts.map(p => ({ attributes: {
    POSITION: accessor(p.positions,'VEC3',5126,true), NORMAL: accessor(p.normals,'VEC3',5126) },
    indices: accessor(p.indices,'SCALAR',5125), material: p.material }))
  const document = { asset:{version:'2.0',generator}, scene:0,
    scenes:[{nodes:[0]}],nodes:[{name,mesh:0}],meshes:[{primitives}],
    materials,buffers:[{byteLength:offset}],bufferViews,accessors }
  const json = Buffer.from(JSON.stringify(document))
  const paddedJson = Buffer.concat([json,Buffer.alloc((4-json.length%4)%4,32)])
  const bin = Buffer.concat(chunks), header = Buffer.alloc(20), binHeader = Buffer.alloc(8)
  header.write('glTF'); header.writeUInt32LE(2,4); header.writeUInt32LE(28+paddedJson.length+bin.length,8)
  header.writeUInt32LE(paddedJson.length,12); header.write('JSON',16)
  binHeader.writeUInt32LE(bin.length); binHeader.write('BIN\0',4)
  const glb = Buffer.concat([header,paddedJson,binHeader,bin])
  const {costs,boundsMm} = validateGlb(glb)
  const digest = createHash('sha256').update(glb).digest('hex')
  return { glb, digest, costs, boundsMm }
}
